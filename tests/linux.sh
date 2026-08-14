#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
installer="$repository_root/public/linux"
test_root="$(mktemp -d)"

cleanup() {
    rm -rf "$test_root"
}
trap cleanup EXIT

if /bin/sh "$installer" >"$test_root/unpublished.out" 2>"$test_root/unpublished.err"; then
    echo "installer continued before the public app release" >&2
    exit 1
fi

grep -Fq "downloads are paused until the first public app release" "$test_root/unpublished.err"
grep -Fq "Follow development on GitHub: https://github.com/BaudBound/baudbound" "$test_root/unpublished.err"

printf 'Linux installer temporary release notice test passed.\n'
