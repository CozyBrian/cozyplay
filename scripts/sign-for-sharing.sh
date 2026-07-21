#!/usr/bin/env bash
#
# sign-for-sharing.sh — make a copy of the built cozyplay.app that can run on OTHER
# Macs. Xcode Debug builds are signed with an "Apple Development" cert + the
# get-task-allow (debuggable) entitlement, which macOS refuses to launch on any Mac
# but the build machine. This re-signs a copy without that flag.
#
# By default it ad-hoc signs (works for a companion, which only plays audio and never
# needs the capture permission). For a stable host build, pass a Developer ID:
#   CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/sign-for-sharing.sh
#
# Usage:
#   scripts/sign-for-sharing.sh            # finds the latest Debug build automatically
#   scripts/sign-for-sharing.sh /path/to/cozyplay.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-}"
IDENTITY="${CODESIGN_IDENTITY:--}"     # "-" = ad-hoc
ENTITLEMENTS="$ROOT/Support/cozyplay-dist.entitlements"
OUT_DIR="$ROOT/dist"
OUT_APP="$OUT_DIR/cozyplay.app"

if [[ -z "$SRC" ]]; then
  SRC="$(find "$HOME/Library/Developer/Xcode/DerivedData" -name cozyplay.app -path '*Debug*' 2>/dev/null | head -1)"
fi
[[ -d "$SRC" ]] || { echo "Could not find a built cozyplay.app. Build it in Xcode first, or pass its path." >&2; exit 1; }

echo "==> Source:   $SRC"
echo "==> Identity: $IDENTITY"
rm -rf "$OUT_APP"
mkdir -p "$OUT_DIR"
cp -R "$SRC" "$OUT_APP"

# Strip anything that would re-quarantine, then sign inside-out.
xattr -cr "$OUT_APP"

# Sign nested helpers/dylibs first (if any were bundled), then the app.
find "$OUT_APP/Contents" \( -name '*.dylib' -o -path '*/Helpers/*' \) -type f 2>/dev/null | while read -r f; do
  codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$f" || true
done
codesign --force --options runtime --timestamp=none \
  --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$OUT_APP"

echo "==> Verifying"
codesign -dv --verbose=4 "$OUT_APP" 2>&1 | grep -E "Authority|flags|Identifier"
codesign -d --entitlements :- "$OUT_APP" 2>/dev/null | grep -q get-task-allow \
  && { echo "!! get-task-allow still present"; exit 1; } || echo "   get-task-allow: removed ✓"

echo
echo "==> Shareable app: $OUT_APP"
echo "Copy it to the other Mac (AirDrop/USB), then on THAT Mac run:"
echo "    xattr -dr com.apple.quarantine /path/to/cozyplay.app"
echo "and right-click the app → Open (once), or approve it in"
echo "System Settings → Privacy & Security → “Open Anyway”."
