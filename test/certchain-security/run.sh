#!/bin/bash
# Build both paths for comparison on a supported macOS host. The target build
# links the exact production shim source; no fallback root or trust override.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GO="$ROOT/src/toolchains/go1.27.3/go/bin/go"
OUT="$ROOT/test/.artifacts/certchain-security"
mkdir -p "$OUT"
export GOTOOLCHAIN=local GOPATH="$ROOT/src/toolchains/gopath"
export GOCACHE="$ROOT/src/toolchains/gocache" CGO_ENABLED=1
clang -arch x86_64 -mmacosx-version-min=11.0 -Wno-deprecated-declarations \
  -Wall -Wextra -Werror -c "$ROOT/shim/macos11_certchain.c" -o "$OUT/shim.o"
GOOS=darwin GOARCH=amd64 GOAMD64=v1 "$GO" build -trimpath -buildmode=exe \
  -ldflags="-macos=11.0 -linkmode external -extldflags '-mmacosx-version-min=11.0 $OUT/shim.o'" \
  -o "$OUT/with-shim" "$ROOT/test/certchain-security/main.go"
GOOS=darwin GOARCH=amd64 GOAMD64=v1 "$GO" build -trimpath -buildmode=exe \
  -o "$OUT/native" "$ROOT/test/certchain-security/main.go"
if nm -u "$OUT/with-shim" | grep -q '_SecTrustCopyCertificateChain$'; then
  echo 'shim build still imports SecTrustCopyCertificateChain' >&2; exit 1
fi
nm "$OUT/with-shim" | grep ' T _SecTrustCopyCertificateChain$'
for item in '1 leaf' '2 intermediate' '3 root'; do
  set -- $item
  awk -v wanted="$1" '/-----BEGIN CERTIFICATE-----/{n++} n==wanted{print}' \
    "$ROOT/test/certchain-fixtures/go.dev-chain.pem" > "$OUT/$2.pem"
  openssl x509 -in "$OUT/$2.pem" -outform der -out "$OUT/$2.der"
done
clang -arch x86_64 -mmacosx-version-min=11.0 -Wno-deprecated-declarations \
  -Wno-unguarded-availability-new -Wall -Wextra -Werror -Wno-nonnull \
  "$ROOT/test/certchain-security/abi.c" "$OUT/shim.o" \
  -framework Security -framework CoreFoundation -o "$OUT/abi"
"$OUT/abi" "$OUT/leaf.der" "$OUT/intermediate.der" "$OUT/root.der"
"$OUT/with-shim" "$ROOT/test/certchain-fixtures/go.dev-chain.pem"
"$OUT/native" "$ROOT/test/certchain-fixtures/go.dev-chain.pem"
