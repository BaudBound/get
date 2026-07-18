#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
installer="$repository_root/deploy/get/public/linux"
test_root="$(mktemp -d)"
fixture_root="$test_root/fixture"
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

mkdir -p "$fixture_root"

mkdir -p "$test_root/missing-dependencies"
if PATH="$test_root/missing-dependencies" /bin/sh "$installer" >"$test_root/missing-dependencies.out" 2>"$test_root/missing-dependencies.err"; then
    echo "installer continued without its required commands" >&2
    exit 1
fi
grep -Fq "required commands are missing: chmod cp curl grep jq ln mkdir mktemp mv rm sha256sum tr uname" "$test_root/missing-dependencies.err"
grep -Fq "No files were downloaded or installed." "$test_root/missing-dependencies.err"
grep -Fq "sudo apt install curl jq coreutils grep" "$test_root/missing-dependencies.err"

cat > "$fixture_root/BaudBound-linux-x86_64.AppImage" <<'SCRIPT'
#!/bin/sh
printf 'baudbound 9.9.9-test\n'
SCRIPT
chmod 0755 "$fixture_root/BaudBound-linux-x86_64.AppImage"
asset_digest="$(sha256sum "$fixture_root/BaudBound-linux-x86_64.AppImage" | cut -d ' ' -f 1)"

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
      "name": "BaudBound-linux-x86_64.AppImage",
      "browser_download_url": "http://127.0.0.1:$port/BaudBound-linux-x86_64.AppImage",
      "digest": "sha256:$asset_digest"
    }
  ]
}
JSON
export BAUDBOUND_ALLOW_INSECURE_TEST_URL=1
export BAUDBOUND_RELEASE_API_URL="http://127.0.0.1:$port/release.json"
export BAUDBOUND_INSTALL_DIR="$test_root/install"
export BAUDBOUND_BIN_DIR="$test_root/bin"

first_output="$(sh "$installer")"
grep -Fq "baudbound 9.9.9-test" <<< "$first_output"
[[ -x "$BAUDBOUND_INSTALL_DIR/BaudBound.AppImage" ]]
[[ -L "$BAUDBOUND_BIN_DIR/baudbound" ]]
[[ "$("$BAUDBOUND_BIN_DIR/baudbound" --version)" == "baudbound 9.9.9-test" ]]

first_checksum="$(sha256sum "$BAUDBOUND_INSTALL_DIR/BaudBound.AppImage")"
second_output="$(sh "$installer")"
grep -Fq "already up to date" <<< "$second_output"
[[ "$(sha256sum "$BAUDBOUND_INSTALL_DIR/BaudBound.AppImage")" == "$first_checksum" ]]

sed -i "s/sha256:$asset_digest/sha256:$(printf '%064d' 0)/" "$fixture_root/release.json"
if sh "$installer" >"$test_root/corrupt.out" 2>"$test_root/corrupt.err"; then
    echo "installer accepted a corrupt checksum" >&2
    exit 1
fi
grep -Fq "checksum does not match" "$test_root/corrupt.err"
[[ "$(sha256sum "$BAUDBOUND_INSTALL_DIR/BaudBound.AppImage")" == "$first_checksum" ]]

printf 'Linux installer tests passed.\n'
