#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
image="baudbound-get:test"
container="baudbound-get-test-$RANDOM"
port="18086"

cleanup() {
    local status="$?"
    if [[ "$status" -ne 0 ]]; then
        printf '%s\n' 'Container endpoint test failed. Container state:' >&2
        docker inspect --format '{{json .State}}' "$container" >&2 || true
        printf '%s\n' 'Container logs:' >&2
        docker logs "$container" >&2 || true
    fi
    docker rm --force "$container" >/dev/null 2>&1 || true
    return "$status"
}
trap cleanup EXIT

docker build --file "$repository_root/deploy/get/Dockerfile" --tag "$image" "$repository_root"
docker run --detach \
    --name "$container" \
    --read-only \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --tmpfs /tmp:rw,noexec,nosuid,size=16m,mode=1777 \
    --publish "127.0.0.1:$port:8080" \
    "$image" >/dev/null

for _ in {1..50}; do
    if curl --fail --silent "http://127.0.0.1:$port/healthz" | grep -Fxq "ok"; then
        break
    fi
    sleep 0.2
done

curl --fail --silent "http://127.0.0.1:$port/healthz" | grep -Fxq "ok"
curl --fail --silent "http://127.0.0.1:$port/linux" \
    | cmp --silent - "$repository_root/deploy/get/public/linux"
curl --fail --silent "http://127.0.0.1:$port/windows" \
    | cmp --silent - "$repository_root/deploy/get/public/windows"

linux_headers="$(curl --silent --dump-header - --output /dev/null "http://127.0.0.1:$port/linux")"
grep -Eiq '^cache-control: no-cache, no-store, must-revalidate\r?$' <<< "$linux_headers"
grep -Eiq '^x-content-type-options: nosniff\r?$' <<< "$linux_headers"

status="$(curl --silent --output /dev/null --write-out '%{http_code}' "http://127.0.0.1:$port/missing")"
[[ "$status" == "404" ]]
status="$(curl --silent --request POST --output /dev/null --write-out '%{http_code}' "http://127.0.0.1:$port/linux")"
[[ "$status" == "403" || "$status" == "405" ]]

printf 'Get service container tests passed.\n'
