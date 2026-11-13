#!/bin/bash
# Package the locally verified 1.104.7 Intel Big Sur candidate assets.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS="${1:-$ROOT/dist/candidate-assets}"
OUTPUT="${2:-$ROOT/dist}"
CLI_ARCHIVE="$ASSETS/tailscale-macos11-x86_64-v1.104.7.tar.gz"
GUI_ARCHIVE="$ASSETS/TailscaleMenu-macos11-x86_64-v1.104.7.zip"
PKG="$OUTPUT/Tailscale-1.104.7-macOS11-Intel.pkg"

check_sha() {
    local expected="$1" file="$2" actual
    [ -f "$file" ] || { echo "Missing release asset: $file" >&2; exit 1; }
    actual="$(/usr/bin/shasum -a 256 "$file" | /usr/bin/awk '{print $1}')"
    [ "$actual" = "$expected" ] || { echo "SHA-256 mismatch: $file" >&2; exit 1; }
}

check_sha 692fc50a8552595dcb238c4604d898b03eba4c5b581f5e6d47253167a7975c3d "$CLI_ARCHIVE"
check_sha 01381c67a44d3e790842fc0fddb4b3076b0bf691b9b6cdd0b563f45b373be071 "$GUI_ARCHIVE"

STAGE="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/tailscale-macos11-pkg.XXXXXXXX")"
trap '/bin/rm -rf "$STAGE"' EXIT
/bin/mkdir -p "$STAGE/input" "$STAGE/root/usr/local/bin" "$STAGE/root/Library/LaunchDaemons" "$STAGE/root/Applications" "$STAGE/scripts" "$OUTPUT"

/usr/bin/tar -xzf "$CLI_ARCHIVE" -C "$STAGE/input"
/usr/bin/ditto -x -k "$GUI_ARCHIVE" "$STAGE/input"

# Exact archive hashes above authenticate the inputs; these checks also catch
# accidental archive layout changes and a truncated local extraction.
[ "$(/usr/bin/find "$STAGE/input" -type l | /usr/bin/wc -l | /usr/bin/tr -d ' ')" = 0 ] || { echo "Unexpected symlink in release assets" >&2; exit 1; }
[ -f "$STAGE/input/tailscale" ] && [ -f "$STAGE/input/tailscaled" ] || { echo "Missing CLI or daemon" >&2; exit 1; }
[ -f "$STAGE/input/TailscaleMenu.app/Contents/Info.plist" ] && [ -f "$STAGE/input/TailscaleMenu.app/Contents/MacOS/TailscaleMenu" ] || { echo "Incomplete menu app" >&2; exit 1; }
check_sha 6d542d812a57a649aa00b5d41730e57ac64b2a1ffa4164fe253bee6c163d23b5 "$STAGE/input/tailscale"
check_sha 62811296d89503a9f359afb88ec5a0342b376085297ffc134aa354f7f89924b5 "$STAGE/input/tailscaled"
check_sha 26be8dc0fdc7ef704a858e82f9140509c74bcb5eca6608e282c5ac11e1703b09 "$STAGE/input/TailscaleMenu.app/Contents/MacOS/TailscaleMenu"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$STAGE/input/TailscaleMenu.app/Contents/Info.plist")" = com.startergo.tailscale-menu ] || { echo "Unexpected menu app identifier" >&2; exit 1; }

/usr/bin/install -m 755 "$STAGE/input/tailscale" "$STAGE/root/usr/local/bin/tailscale"
/usr/bin/install -m 755 "$STAGE/input/tailscaled" "$STAGE/root/usr/local/bin/tailscaled"
/usr/bin/install -m 644 "$ROOT/deploy/com.tailscale.tailscaled.macos11.plist" "$STAGE/root/Library/LaunchDaemons/com.tailscale.tailscaled.plist"
/usr/bin/ditto "$STAGE/input/TailscaleMenu.app" "$STAGE/root/Applications/TailscaleMenu.app"
/bin/cp "$ROOT/installer/macos11-scripts/preinstall" "$ROOT/installer/macos11-scripts/postinstall" "$ROOT/installer/macos11-scripts/validate-plist.rb" "$STAGE/scripts/"
/bin/chmod 755 "$STAGE/scripts/preinstall" "$STAGE/scripts/postinstall"
/usr/bin/xattr -cr "$STAGE/root" "$STAGE/scripts"

/usr/bin/pkgbuild --root "$STAGE/root" --scripts "$STAGE/scripts" \
    --identifier com.dankhan.tailscale-macos11-intel --version 1.104.7 \
    --install-location / --ownership recommended \
    --component-plist "$ROOT/installer/macos11-components.plist" "$PKG"
echo "Built $PKG"
/usr/bin/shasum -a 256 "$PKG"
