#!/usr/bin/env bash
# Builds dist/QuickConvert.app and dist/QuickConvert-<version>.dmg (ad hoc signed, not notarized).
# Requires vendor/ffmpeg-<arch> from build-ffmpeg.sh for every architecture being shipped.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-1}"
BUNDLE_ID="${BUNDLE_ID:-app.quickconvert.QuickConvert}"
ARCHS=(${ARCHS:-arm64 x86_64})
DIST="$ROOT/dist"
APP="$DIST/QuickConvert.app"
cd "$ROOT"

arch_flags=()
for arch in "${ARCHS[@]}"; do arch_flags+=(--arch "$arch"); done
swift build -c release "${arch_flags[@]}"
BIN="$(swift build -c release "${arch_flags[@]}" --show-bin-path)/QuickConvert"

rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Tools" "$APP/Contents/Resources/Licenses"
cp "$BIN" "$APP/Contents/MacOS/QuickConvert"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" -e "s/__BUNDLE_ID__/$BUNDLE_ID/" Packaging/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"

ICONSET="$DIST/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size Assets/AppIcon-1024.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) Assets/AppIcon-1024.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

for tool in ffmpeg ffprobe; do
  slices=()
  for arch in "${ARCHS[@]}"; do slices+=("vendor/ffmpeg-$arch/bin/$tool"); done
  lipo -create "${slices[@]}" -output "$APP/Contents/Resources/Tools/$tool"
  chmod +x "$APP/Contents/Resources/Tools/$tool"
done
cp vendor/ffmpeg-"${ARCHS[0]}"/licenses/* "$APP/Contents/Resources/Licenses/"

# Every executable must contain every advertised architecture.
for bin in "$APP/Contents/MacOS/QuickConvert" "$APP"/Contents/Resources/Tools/*; do
  for arch in "${ARCHS[@]}"; do
    lipo "$bin" -verify_arch "$arch" || { echo "$bin is missing $arch" >&2; exit 1; }
  done
done

codesign --force --sign - "$APP"/Contents/Resources/Tools/*
codesign --force --sign - "$APP"
codesign --verify --strict --verbose=2 "$APP"

STAGE="$DIST/dmg"
DMG="$DIST/QuickConvert-$VERSION.dmg"
rm -rf "$STAGE" "$DMG" && mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname QuickConvert -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "Built $DMG ($(IFS=,; echo "${ARCHS[*]}"))"
