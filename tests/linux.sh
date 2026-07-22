#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
installer="$repository_root/deploy/get/public/linux"
test_root="$(mktemp -d)"
fixture_root="$test_root/fixture"
fake_bin="$test_root/bin"
port_file="$test_root/port"
server_pid=""

cleanup() {
    if [[ -n "$server_pid" ]]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -rf "$test_root"
}
trap cleanup EXIT

mkdir -p "$fixture_root" "$fake_bin"

mkdir -p "$test_root/missing-dependencies"
if PATH="$test_root/missing-dependencies" /bin/sh "$installer" >"$test_root/missing.out" 2>"$test_root/missing.err"; then
    echo "installer continued without its required commands" >&2
    exit 1
fi
grep -Fq "required commands are missing" "$test_root/missing.err"
grep -Fq "No files were downloaded or installed." "$test_root/missing.err"

printf 'test deb package\n' > "$fixture_root/BaudBound_9.9.9_amd64.deb"
printf 'test rpm package\n' > "$fixture_root/BaudBound-9.9.9-1.x86_64.rpm"
deb_digest="$(sha256sum "$fixture_root/BaudBound_9.9.9_amd64.deb" | cut -d ' ' -f 1)"
rpm_digest="$(sha256sum "$fixture_root/BaudBound-9.9.9-1.x86_64.rpm" | cut -d ' ' -f 1)"

python3 - "$fixture_root" "$port_file" <<'PY' &
import http.server
import os
import socketserver
import sys

root, port_file = sys.argv[1:]
os.chdir(root)
handler = http.server.SimpleHTTPRequestHandler
with socketserver.TCPServer(("127.0.0.1", 0), handler) as server:
    with open(port_file, "w", encoding="ascii") as output:
        output.write(str(server.server_address[1]))
    server.serve_forever()
PY
server_pid=$!

for _ in {1..50}; do
    [[ -s "$port_file" ]] && break
    sleep 0.1
done
[[ -s "$port_file" ]] || { echo "fixture server did not start" >&2; exit 1; }

port="$(cat "$port_file")"
cat > "$fixture_root/release.json" <<JSON
{
  "tag_name": "v9.9.9",
  "assets": [
    {
      "name": "BaudBound_9.9.9_amd64.deb",
      "browser_download_url": "http://127.0.0.1:$port/BaudBound_9.9.9_amd64.deb",
      "digest": "sha256:$deb_digest"
    },
    {
      "name": "BaudBound-9.9.9-1.x86_64.rpm",
      "browser_download_url": "http://127.0.0.1:$port/BaudBound-9.9.9-1.x86_64.rpm",
      "digest": "sha256:$rpm_digest"
    }
  ]
}
JSON

cat > "$fake_bin/sudo" <<'SH'
#!/bin/sh
exec "$@"
SH
cat > "$fake_bin/uname" <<'SH'
#!/bin/sh
case "${1:-}" in
    -s) printf '%s\n' "${BAUDBOUND_TEST_UNAME_S:-Linux}" ;;
    -m) printf '%s\n' "${BAUDBOUND_TEST_UNAME_M:-x86_64}" ;;
    *) exec /usr/bin/uname "$@" ;;
esac
SH
cat > "$fake_bin/apt" <<'SH'
#!/bin/sh
printf '%s\n' "$*" > "$BAUDBOUND_TEST_COMMAND_FILE"
SH
cat > "$fake_bin/dnf" <<'SH'
#!/bin/sh
printf '%s\n' "$*" > "$BAUDBOUND_TEST_COMMAND_FILE"
SH
cat > "$fake_bin/dpkg-query" <<'SH'
#!/bin/sh
if [ -n "${BAUDBOUND_TEST_INSTALLED_VERSION:-}" ]; then
    printf '%s' "$BAUDBOUND_TEST_INSTALLED_VERSION"
    exit 0
fi
exit 1
SH
cat > "$fake_bin/dpkg" <<'SH'
#!/bin/sh
if [ "${1:-}" != "--compare-versions" ]; then
    exit 1
fi
current="$2"
operator="$3"
available="$4"
case "$operator:$current:$available" in
    eq:*:*) [ "$current" = "$available" ] ;;
    lt:9.8.0:9.9.9) exit 0 ;;
    lt:*:*) exit 1 ;;
    *) exit 1 ;;
esac
SH
cat > "$fake_bin/dpkg-deb" <<'SH'
#!/bin/sh
case "$3" in
    Package) printf 'baud-bound\n' ;;
    Version) printf '9.9.9\n' ;;
    Architecture) printf 'amd64\n' ;;
    *) exit 1 ;;
esac
SH
cat > "$fake_bin/rpm" <<'SH'
#!/bin/sh
if [ "${1:-}" = "--eval" ]; then
    case "${BAUDBOUND_TEST_INSTALLED_VERSION:-}:${BAUDBOUND_AVAILABLE_VERSION:-}" in
        9.8.0:9.9.9) printf '%s' '-1' ;;
        9.9.9:9.9.9) printf '%s' '0' ;;
        10.0.0:9.9.9) printf '%s' '1' ;;
        *) exit 1 ;;
    esac
    exit 0
fi
case "${3:-}" in
    '%{NAME}') [ "${1:-}" = "-qp" ] && printf 'baud-bound' || exit 1 ;;
    '%{VERSION}')
        if [ "${1:-}" = "-qp" ]; then
            printf '9.9.9'
        elif [ "${1:-}" = "-q" ] && [ -n "${BAUDBOUND_TEST_INSTALLED_VERSION:-}" ]; then
            printf '%s' "$BAUDBOUND_TEST_INSTALLED_VERSION"
        else
            exit 1
        fi
        ;;
    '%{ARCH}') [ "${1:-}" = "-qp" ] && printf 'x86_64' || exit 1 ;;
    *)
        if [ "${1:-}" = "-q" ] && [ -n "${BAUDBOUND_TEST_INSTALLED_VERSION:-}" ]; then
            printf '%s' "$BAUDBOUND_TEST_INSTALLED_VERSION"
            exit 0
        fi
        exit 1
        ;;
esac
SH
chmod 0755 "$fake_bin"/*

export PATH="$fake_bin:/usr/local/bin:/usr/bin:/bin"
export BAUDBOUND_ALLOW_INSECURE_TEST_URL=1
export BAUDBOUND_RELEASE_API_URL="http://127.0.0.1:$port/release.json"
export BAUDBOUND_APPIMAGE_PATH="$test_root/no-appimage"
export BAUDBOUND_APPIMAGE_COMMAND_PATH="$test_root/no-command"
export BAUDBOUND_APPIMAGE_LAUNCHER_PATH="$test_root/no-launcher"
export BAUDBOUND_APPIMAGE_IDENTIFIER_LAUNCHER_PATH="$test_root/no-identifier-launcher"

run_installer() {
    script --quiet --return --command "sh '$installer'" /dev/null
}

cat > "$test_root/debian-os-release" <<'EOF'
ID=debian
PRETTY_NAME="Debian GNU/Linux 13"
EOF
export BAUDBOUND_OS_RELEASE_FILE="$test_root/debian-os-release"
export BAUDBOUND_TEST_COMMAND_FILE="$test_root/debian-command"
debian_output="$(run_installer)"
grep -Fq "Detected Debian GNU/Linux 13" <<< "$debian_output"
grep -Fq "use the deb package and APT" <<< "$debian_output"
grep -Fq "BaudBound 9.9.9 is installed" <<< "$debian_output"
grep -Eq '^install .*/BaudBound_9\.9\.9_amd64\.deb$' "$BAUDBOUND_TEST_COMMAND_FILE"

rm -f "$BAUDBOUND_TEST_COMMAND_FILE"
export BAUDBOUND_TEST_INSTALLED_VERSION=9.9.9
debian_current_output="$(run_installer)"
grep -Fq "BaudBound 9.9.9 is already installed and up to date" <<< "$debian_current_output"
[[ ! -e "$BAUDBOUND_TEST_COMMAND_FILE" ]] || {
    echo "installer invoked APT for an already current package" >&2
    exit 1
}
unset BAUDBOUND_TEST_INSTALLED_VERSION

export BAUDBOUND_APPIMAGE_PATH="$test_root/BaudBound.AppImage"
printf 'old AppImage\n' > "$BAUDBOUND_APPIMAGE_PATH"
if run_installer >"$test_root/appimage.out" 2>"$test_root/appimage.err"; then
    echo "installer accepted a conflicting AppImage installation" >&2
    exit 1
fi
grep -Fq "an existing AppImage installation was found" "$test_root/appimage.out" "$test_root/appimage.err"
grep -Fq "No files were downloaded or installed" "$test_root/appimage.out" "$test_root/appimage.err"
rm -f "$BAUDBOUND_APPIMAGE_PATH"
export BAUDBOUND_APPIMAGE_PATH="$test_root/no-appimage"

export BAUDBOUND_TEST_INSTALLED_VERSION=9.8.0
debian_update_output="$(run_installer)"
grep -Fq "Updating BaudBound from 9.8.0 to 9.9.9 with APT" <<< "$debian_update_output"
unset BAUDBOUND_TEST_INSTALLED_VERSION

export BAUDBOUND_TEST_INSTALLED_VERSION=10.0.0
if run_installer >"$test_root/downgrade.out" 2>"$test_root/downgrade.err"; then
    echo "installer accepted a package downgrade" >&2
    exit 1
fi
grep -Fq "installed BaudBound 10.0.0 is newer than release 9.9.9" \
    "$test_root/downgrade.out" "$test_root/downgrade.err"
grep -Fq "Downgrades are not supported" "$test_root/downgrade.out" "$test_root/downgrade.err"
unset BAUDBOUND_TEST_INSTALLED_VERSION

cat > "$test_root/ubuntu-os-release" <<'EOF'
ID=ubuntu
PRETTY_NAME="Ubuntu"
EOF
export BAUDBOUND_OS_RELEASE_FILE="$test_root/ubuntu-os-release"
export BAUDBOUND_TEST_COMMAND_FILE="$test_root/ubuntu-command"
ubuntu_output="$(run_installer)"
grep -Fq "Detected Ubuntu" <<< "$ubuntu_output"
grep -Fq "use the deb package and APT" <<< "$ubuntu_output"
grep -Eq '^install .*/BaudBound_9\.9\.9_amd64\.deb$' "$BAUDBOUND_TEST_COMMAND_FILE"

cat > "$test_root/fedora-os-release" <<'EOF'
ID=fedora
PRETTY_NAME="Fedora Linux"
EOF
export BAUDBOUND_OS_RELEASE_FILE="$test_root/fedora-os-release"
export BAUDBOUND_TEST_COMMAND_FILE="$test_root/fedora-command"
fedora_output="$(run_installer)"
grep -Fq "Detected Fedora Linux" <<< "$fedora_output"
grep -Fq "use the rpm package and DNF" <<< "$fedora_output"
grep -Eq '^install .*/BaudBound-9\.9\.9-1\.x86_64\.rpm$' "$BAUDBOUND_TEST_COMMAND_FILE"

rm -f "$BAUDBOUND_TEST_COMMAND_FILE"
export BAUDBOUND_TEST_INSTALLED_VERSION=9.9.9
fedora_current_output="$(run_installer)"
grep -Fq "BaudBound 9.9.9 is already installed and up to date" <<< "$fedora_current_output"
[[ ! -e "$BAUDBOUND_TEST_COMMAND_FILE" ]] || {
    echo "installer invoked DNF for an already current package" >&2
    exit 1
}

export BAUDBOUND_TEST_INSTALLED_VERSION=9.8.0
fedora_update_output="$(run_installer)"
grep -Fq "Updating BaudBound from 9.8.0 to 9.9.9 with DNF" <<< "$fedora_update_output"

export BAUDBOUND_TEST_INSTALLED_VERSION=10.0.0
if run_installer >"$test_root/rpm-downgrade.out" 2>"$test_root/rpm-downgrade.err"; then
    echo "installer accepted an RPM package downgrade" >&2
    exit 1
fi
grep -Fq "installed BaudBound 10.0.0 is newer than release 9.9.9" \
    "$test_root/rpm-downgrade.out" "$test_root/rpm-downgrade.err"
unset BAUDBOUND_TEST_INSTALLED_VERSION

cat > "$test_root/arch-os-release" <<'EOF'
ID=arch
PRETTY_NAME="Arch Linux"
EOF
export BAUDBOUND_OS_RELEASE_FILE="$test_root/arch-os-release"
if run_installer >"$test_root/arch.out" 2>"$test_root/arch.err"; then
    echo "installer accepted an unsupported distribution" >&2
    exit 1
fi
grep -Fq "Arch Linux is not supported by the automatic installer" "$test_root/arch.out" "$test_root/arch.err"
grep -Fq "No files were downloaded or installed" "$test_root/arch.out" "$test_root/arch.err"
grep -Fq "GitHub Releases" "$test_root/arch.out" "$test_root/arch.err"

export BAUDBOUND_TEST_UNAME_M=aarch64
if run_installer >"$test_root/architecture.out" 2>"$test_root/architecture.err"; then
    echo "installer accepted an unsupported architecture" >&2
    exit 1
fi
grep -Fq "only 64-bit x86 Linux is currently supported" "$test_root/architecture.out" "$test_root/architecture.err"
unset BAUDBOUND_TEST_UNAME_M

export BAUDBOUND_OS_RELEASE_FILE="$test_root/ubuntu-os-release"
cp "$fixture_root/release.json" "$fixture_root/release-valid.json"
jq 'del(.assets[] | select(.name | endswith(".deb")))' \
    "$fixture_root/release-valid.json" > "$fixture_root/release.json"
if run_installer >"$test_root/missing-asset.out" 2>"$test_root/missing-asset.err"; then
    echo "installer continued without a Debian release asset" >&2
    exit 1
fi
grep -Fq "exactly one deb package for amd64" "$test_root/missing-asset.out" "$test_root/missing-asset.err"
cp "$fixture_root/release-valid.json" "$fixture_root/release.json"

missing_apt_bin="$test_root/no-apt-bin"
mkdir -p "$missing_apt_bin"
for command_name in curl id jq mktemp rm sha256sum tr; do
    ln -s "$(command -v "$command_name")" "$missing_apt_bin/$command_name"
done
for command_name in dpkg dpkg-deb dpkg-query sudo uname; do
    ln -s "$fake_bin/$command_name" "$missing_apt_bin/$command_name"
done
if script --quiet --return \
    --command "env PATH='$missing_apt_bin' /bin/sh '$installer'" /dev/null \
    >"$test_root/missing-apt.out" 2>"$test_root/missing-apt.err"; then
    echo "installer continued without APT" >&2
    exit 1
fi
grep -Fq "required commands for Ubuntu are missing: apt" "$test_root/missing-apt.out" "$test_root/missing-apt.err"

if setsid -w /bin/sh "$installer" </dev/null >"$test_root/noninteractive.out" 2>"$test_root/noninteractive.err"; then
    echo "installer continued without an interactive terminal" >&2
    exit 1
fi
grep -Fq "an interactive terminal is required" "$test_root/noninteractive.out" "$test_root/noninteractive.err"

sed -i "s/sha256:$deb_digest/sha256:$(printf '%064d' 0)/" "$fixture_root/release.json"
if run_installer >"$test_root/corrupt.out" 2>"$test_root/corrupt.err"; then
    echo "installer accepted a corrupt checksum" >&2
    exit 1
fi
grep -Fq "checksum does not match" "$test_root/corrupt.out" "$test_root/corrupt.err"

printf 'Linux installer tests passed.\n'
