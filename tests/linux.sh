#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
installer="$repository_root/public/linux"
test_root="$(mktemp -d)"

cleanup() {
    rm -rf "$test_root"
}
trap cleanup EXIT

if /bin/sh "$installer" >"$test_root/paused.out" 2>"$test_root/paused.err"; then
    echo "installer continued while downloads are paused" >&2
    exit 1
fi
grep -Fq "downloads are paused until the first public app release" "$test_root/paused.err"

grep -Fxq "downloads_enabled=0" "$installer" \
    || { echo "pause seam 'downloads_enabled=0' is missing from the installer" >&2; exit 1; }

enabled="$test_root/linux-enabled"
sed 's/^downloads_enabled=0$/downloads_enabled=1/' "$installer" >"$enabled"
chmod +x "$enabled"

run_case() {
    local machine="$1" os_id="$2" expected="$3"
    local output
    output="$(BAUDBOUND_TEST_UNAME_M="$machine" BAUDBOUND_TEST_OS_ID="$os_id" \
        BAUDBOUND_TEST_PLAN_ONLY=1 /bin/sh "$enabled" 2>&1)" || true
    printf '%s' "$output" | grep -Fq "$expected" \
        || { echo "case $machine/$os_id expected '$expected', got: $output" >&2; exit 1; }
}

run_case x86_64 debian "amd64.deb"
run_case x86_64 ubuntu "amd64.deb"
run_case x86_64 fedora "x86_64.rpm"
run_case aarch64 debian "arm64.deb"
run_case aarch64 ubuntu "arm64.deb"
run_case aarch64 fedora "aarch64.rpm"
run_case arm64 debian "arm64.deb"
run_case armv7l debian "unsupported CPU architecture"
run_case i686 debian "unsupported CPU architecture"
run_case riscv64 debian "unsupported CPU architecture"
run_case x86_64 arch "no tested native package"

# The format permits quoting, and a sourced file would have removed it for
# free. Reading the value textually has to strip it deliberately, so it is
# tested deliberately.
os_release_case() {
    local contents="$1" expected="$2"
    local sandbox output
    sandbox="$test_root/os-release-$RANDOM"
    mkdir -p "$sandbox/etc"
    printf '%s\n' "$contents" >"$sandbox/etc/os-release"
    local scoped="$sandbox/linux"
    sed "s#/etc/os-release#$sandbox/etc/os-release#g" "$enabled" >"$scoped"
    output="$(BAUDBOUND_TEST_UNAME_M=aarch64 BAUDBOUND_TEST_PLAN_ONLY=1 \
        /bin/sh "$scoped" 2>&1)" || true
    printf '%s' "$output" | grep -Fq "$expected" \
        || { echo "os-release case expected '$expected', got: $output" >&2; exit 1; }
}

os_release_case 'ID=debian' "arm64.deb"
os_release_case 'ID="debian"' "arm64.deb"
os_release_case "ID='debian'" "arm64.deb"
os_release_case 'NAME="Whatever"
ID=fedora
VERSION_ID="43"' "aarch64.rpm"
os_release_case 'NAME="No identifier here"' "could not identify this system"

# A sourced os-release would run this. A parsed one reports the value and the
# character-class check refuses it.
os_release_case 'ID=debian$(touch '"$test_root"'/pwned)' "could not identify this system"
[[ ! -e "$test_root/pwned" ]] || { echo "os-release contents were executed" >&2; exit 1; }

printf 'Linux installer architecture and distribution tests passed.\n'
