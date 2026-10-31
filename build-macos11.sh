#!/bin/bash
# Build the Intel macOS 11 binaries from the pinned upstream release.
# Keep the upstream checkout and Go toolchain under ignored src/ or pass
# SOURCE and GO paths to equivalent isolated locations.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SOURCE="${SOURCE:-$ROOT/src/tailscale-upstream}"
GO="${GO:-$ROOT/src/toolchains/go1.27.3/go/bin/go}"
PIN=27047635f237d1f3e0b08c0f487674757f30d2f7
VERSION=1.104.4

test -x "$GO" || { echo "missing isolated Go 1.27.3: $GO" >&2; exit 1; }
case "$("$GO" version)" in
    'go version go1.27.3 darwin/arm64'|'go version go1.27.3 darwin/amd64') ;;
    *) echo "unexpected Go toolchain" >&2; exit 1 ;;
esac
test "$(git -C "$SOURCE" rev-parse HEAD)" = "$PIN" || {
    echo "upstream source is not the pinned v$VERSION commit" >&2; exit 1;
}
test "$(sed -n 's/^go //p' "$SOURCE/go.mod")" = '1.27.3' || {
    echo "unexpected upstream go.mod requirement" >&2; exit 1;
}
test -z "$(git -C "$SOURCE" status --porcelain)" || {
    echo "upstream source is modified" >&2; exit 1;
}

mkdir -p "$ROOT/out-macos11" "$ROOT/src/toolchains/gopath" "$ROOT/src/toolchains/gocache"
export GOTOOLCHAIN=local GOPATH="$ROOT/src/toolchains/gopath"
export GOCACHE="$ROOT/src/toolchains/gocache"
export CGO_ENABLED=1 GOOS=darwin GOARCH=amd64 GOAMD64=v1
export CC=clang CGO_CFLAGS=-mmacosx-version-min=11.0
export MACOSX_DEPLOYMENT_TARGET=11.0

clang -arch x86_64 -mmacosx-version-min=11.0 -Wno-deprecated-declarations \
    -Wall -Wextra -Werror \
    -c "$ROOT/shim/macos11_certchain.c" -o "$ROOT/out-macos11/macos11_certchain.o"
LDFLAGS="-macos=11.0 -linkmode external -extldflags '-mmacosx-version-min=11.0 $ROOT/out-macos11/macos11_certchain.o' -X tailscale.com/version.longStamp=$VERSION -X tailscale.com/version.shortStamp=$VERSION -X tailscale.com/version.gitCommitStamp=$PIN"
for cmd in tailscale tailscaled; do
    "$GO" -C "$SOURCE" build -trimpath -buildvcs=false -buildmode=exe \
        -ldflags "$LDFLAGS" -o "$ROOT/out-macos11/$cmd" "./cmd/$cmd"
done
shasum -a 256 "$ROOT/out-macos11/tailscale" "$ROOT/out-macos11/tailscaled"
