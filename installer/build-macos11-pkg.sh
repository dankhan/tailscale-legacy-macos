#!/bin/bash
# Package the published, verified 1.104.4 Intel Big Sur release assets.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS="${1:-$ROOT/dist/release-assets}"
OUTPUT="${2:-$ROOT/dist}"
CLI_ARCHIVE="$ASSETS/tailscale-macos11-x86_64-v1.104.4.tar.gz"
GUI_ARCHIVE="$ASSETS/TailscaleMenu-macos11-x86_64-v1.104.4.zip"
PKG="$OUTPUT/Tailscale-1.104.4-macOS11-Intel.pkg"

check_sha() {
    local expected="$1" file="$2" actual
    [ -f "$file" ] || { echo "Missing release asset: $file" >&2; exit 1; }
    actual="$(/usr/bin/shasum -a 256 "$file" | /usr/bin/awk '{print $1}')"
    [ "$actual" = "$expected" ] || { echo "SHA-256 mismatch: $file" >&2; exit 1; }
}

check_sha 819f4107884e12176c44f9e49a959f3ee4d52761d7c6bbbc64cf7ddfdde8a0d1 "$CLI_ARCHIVE"
check_sha db4efdf9e922c6243ffb6c22dfdf179745e80b14c24316389adf8cd43f1bc270 "$GUI_ARCHIVE"

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
check_sha 6e9505c4b9969e9a2cd58e9f2d3c0913c5a6c0173f721b009af2be2af4c472cb "$STAGE/input/tailscale"
check_sha 689d47a7f40933aa872cb530bc573d83b349328339c8849ad1dba5061d0436ce "$STAGE/input/tailscaled"
check_sha 7ce45c2a268618f7a52b663c5db273fa146026111d0811df2a10a35fd97adede "$STAGE/input/TailscaleMenu.app/Contents/MacOS/TailscaleMenu"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$STAGE/input/TailscaleMenu.app/Contents/Info.plist")" = com.startergo.tailscale-menu ] || { echo "Unexpected menu app identifier" >&2; exit 1; }

/usr/bin/install -m 755 "$STAGE/input/tailscale" "$STAGE/root/usr/local/bin/tailscale"
/usr/bin/install -m 755 "$STAGE/input/tailscaled" "$STAGE/root/usr/local/bin/tailscaled"
/usr/bin/install -m 644 "$ROOT/deploy/com.tailscale.tailscaled.macos11.plist" "$STAGE/root/Library/LaunchDaemons/com.tailscale.tailscaled.plist"
/usr/bin/ditto "$STAGE/input/TailscaleMenu.app" "$STAGE/root/Applications/TailscaleMenu.app"
/bin/cp "$ROOT/installer/macos11-scripts/preinstall" "$ROOT/installer/macos11-scripts/postinstall" "$STAGE/scripts/"
/usr/bin/install -m 644 "$ROOT/deploy/com.tailscale.tailscaled.macos11.plist" "$STAGE/scripts/expected-plist"
/bin/chmod 755 "$STAGE/scripts/preinstall" "$STAGE/scripts/postinstall"
/usr/bin/xattr -cr "$STAGE/root" "$STAGE/scripts"

/usr/bin/pkgbuild --root "$STAGE/root" --scripts "$STAGE/scripts" \
    --identifier com.dankhan.tailscale-macos11-intel --version 1.104.4 \
    --install-location / --ownership recommended \
    --component-plist "$ROOT/installer/macos11-components.plist" "$PKG"
echo "Built $PKG"
/usr/bin/shasum -a 256 "$PKG"
