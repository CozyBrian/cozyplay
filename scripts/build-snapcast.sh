#!/usr/bin/env bash
#
# build-snapcast.sh — build snapserver + snapclient from source (arm64) and relocate
# them, with their dylibs, into the cozyplay app bundle's Contents/Helpers directory.
#
# For LOCAL DEVELOPMENT you don't need this: `brew install snapcast` is enough — the
# app falls back to /opt/homebrew/bin (see SnapcastBinaries.swift). This script is for
# producing a self-contained, distributable .app.
#
# Snapcast is GPL-3.0. If you distribute the resulting .app you must also provide the
# corresponding source (or a written offer) and preserve its license notices.
#
# Usage:
#   scripts/build-snapcast.sh /path/to/cozyplay.app
#   SNAPCAST_REF=v0.35.0 scripts/build-snapcast.sh /path/to/cozyplay.app
set -euo pipefail

APP_PATH="${1:-}"
SNAPCAST_REF="${SNAPCAST_REF:-v0.35.0}"
BUILD_DIR="$(cd "$(dirname "$0")/.." && pwd)/.build/snapcast"

if [[ -z "$APP_PATH" ]]; then
  echo "usage: $0 /path/to/cozyplay.app   (the built .app to inject helpers into)" >&2
  exit 1
fi

HELPERS_DIR="$APP_PATH/Contents/Helpers"

echo "==> Checking build tools"
command -v brew >/dev/null || { echo "Homebrew required: https://brew.sh" >&2; exit 1; }
for tool in cmake git; do
  command -v "$tool" >/dev/null || { echo "Installing $tool"; brew install "$tool"; }
done

echo "==> Installing Snapcast build dependencies (brew)"
# Runtime libs Snapcast links against; we'll bundle these dylibs alongside the binaries.
brew install boost flac libvorbis opus libsoxr openssl@3 expat || true

echo "==> Fetching Snapcast $SNAPCAST_REF"
mkdir -p "$BUILD_DIR"
if [[ ! -d "$BUILD_DIR/src/.git" ]]; then
  git clone --depth 1 --branch "$SNAPCAST_REF" https://github.com/snapcast/snapcast.git "$BUILD_DIR/src"
fi

echo "==> Configuring + building (arm64)"
cmake -S "$BUILD_DIR/src" -B "$BUILD_DIR/out" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DBUILD_TESTS=OFF
cmake --build "$BUILD_DIR/out" -j"$(sysctl -n hw.ncpu)"

echo "==> Locating built binaries"
SNAPSERVER="$(find "$BUILD_DIR/out" -name snapserver -type f -perm +111 | head -1)"
SNAPCLIENT="$(find "$BUILD_DIR/out" -name snapclient -type f -perm +111 | head -1)"
[[ -x "$SNAPSERVER" && -x "$SNAPCLIENT" ]] || { echo "build did not produce both binaries" >&2; exit 1; }

echo "==> Injecting into $HELPERS_DIR"
mkdir -p "$HELPERS_DIR"
cp "$SNAPSERVER" "$SNAPCLIENT" "$HELPERS_DIR/"

# Relocate non-system dylib dependencies to @loader_path so the helpers run without
# Homebrew present on the target machine.
relocate() {
  local bin="$1"
  # Copy each /opt/homebrew (or /usr/local) dylib next to the binary and rewrite paths.
  otool -L "$bin" | awk 'NR>1 {print $1}' | grep -E '^(/opt/homebrew|/usr/local)' | while read -r dep; do
    local base; base="$(basename "$dep")"
    [[ -f "$HELPERS_DIR/$base" ]] || cp "$dep" "$HELPERS_DIR/$base"
    install_name_tool -change "$dep" "@loader_path/$base" "$bin"
    chmod u+w "$HELPERS_DIR/$base"
  done
}

for bin in "$HELPERS_DIR/snapserver" "$HELPERS_DIR/snapclient"; do
  chmod u+w "$bin"
  relocate "$bin"
done
# One more pass so bundled dylibs resolve each other via @loader_path.
for dylib in "$HELPERS_DIR"/*.dylib; do
  [[ -e "$dylib" ]] || continue
  relocate "$dylib"
done

echo "==> Re-signing helpers with Hardened Runtime"
IDENTITY="${CODESIGN_IDENTITY:--}"   # default ad-hoc for dev; set CODESIGN_IDENTITY for distribution
for f in "$HELPERS_DIR"/snapserver "$HELPERS_DIR"/snapclient "$HELPERS_DIR"/*.dylib; do
  [[ -e "$f" ]] || continue
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$f"
done

echo "==> Done. Helpers in $HELPERS_DIR:"
ls -1 "$HELPERS_DIR"
echo
echo "If you set CODESIGN_IDENTITY to a Developer ID, remove"
echo "com.apple.security.cs.disable-library-validation from the entitlements and re-sign the app."
