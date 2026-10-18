#!/usr/bin/env bash
# Builds a static, LGPL-only ffmpeg + ffprobe for the host architecture into vendor/ffmpeg-<arch>.
# Run once on an arm64 Mac and once on an Intel Mac; package.sh merges them with lipo.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="$(uname -m)"
OUT="$ROOT/vendor/ffmpeg-$ARCH"
WORK="$ROOT/vendor/build-$ARCH"
PREFIX="$WORK/prefix"
SUMS="$ROOT/scripts/ffmpeg-sources.sha256"
export MACOSX_DEPLOYMENT_TARGET=14.0
export CFLAGS="-O2 -mmacosx-version-min=14.0"
export LDFLAGS="-mmacosx-version-min=14.0"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
JOBS="$(sysctl -n hw.ncpu)"

SOURCES=(
  "https://ffmpeg.org/releases/ffmpeg-7.1.1.tar.xz"
  "https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz"
  "https://downloads.xiph.org/releases/ogg/libogg-1.3.5.tar.xz"
  "https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.xz"
  "https://github.com/webmproject/libvpx/archive/refs/tags/v1.15.0.tar.gz"
  "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.5.0.tar.gz"
)

mkdir -p "$WORK/src" "$PREFIX" "$OUT/bin" "$OUT/licenses"
cd "$WORK/src"
for url in "${SOURCES[@]}"; do
  file="$(basename "$url")"
  [[ "$file" == v1.15.0.tar.gz ]] && file="libvpx-1.15.0.tar.gz"
  [[ -f "$file" ]] || curl -fL --retry 3 -o "$file" "$url"
  sum="$(shasum -a 256 "$file" | cut -d' ' -f1)"
  pinned="$(grep " $file\$" "$SUMS" 2>/dev/null | cut -d' ' -f1 || true)"
  if [[ -z "$pinned" ]]; then
    echo "No pinned checksum for $file ($sum). Review it, then add '$sum  $file' to scripts/ffmpeg-sources.sha256." >&2
    [[ "${QC_RECORD_CHECKSUMS:-0}" == 1 ]] && echo "$sum  $file" >> "$SUMS" || exit 1
  elif [[ "$sum" != "$pinned" ]]; then
    echo "Checksum mismatch for $file" >&2; exit 1
  fi
  dir="${file%.tar.*}"
  [[ -d "$dir" ]] || { mkdir "$dir"; tar -xf "$file" -C "$dir" --strip-components 1; }
done

build_autotools() {
  (cd "$1" && ./configure --prefix="$PREFIX" --disable-shared --enable-static "${@:2}" && make -j"$JOBS" && make install)
}

build_autotools lame-3.100 --disable-frontend --disable-decoder
build_autotools libogg-1.3.5
# libvorbis 1.3.7 passes a linker flag modern Apple ld rejects.
sed -i '' 's/-force_cpusubtype_ALL//g' libvorbis-1.3.7/configure
build_autotools libvorbis-1.3.7 --with-ogg="$PREFIX"
build_autotools libwebp-1.5.0 --disable-gl --disable-sdl --disable-png --disable-jpeg --disable-tiff --disable-gif --disable-wic
(cd libvpx-1.15.0 && ./configure --prefix="$PREFIX" --target="$ARCH-darwin23-gcc" --disable-shared --enable-static \
  --enable-pic --disable-examples --disable-tools --disable-docs --disable-unit-tests --enable-vp8 --enable-vp9 \
  && make -j"$JOBS" && make install)

(cd ffmpeg-7.1.1 && ./configure --prefix="$PREFIX" --pkg-config-flags=--static \
  --extra-cflags="-I$PREFIX/include $CFLAGS" --extra-ldflags="-L$PREFIX/lib $LDFLAGS" \
  --disable-autodetect --disable-network --disable-debug --disable-doc --disable-ffplay \
  --enable-zlib --enable-videotoolbox --enable-audiotoolbox \
  --enable-libmp3lame --enable-libvorbis --enable-libvpx --enable-libwebp \
  && make -j"$JOBS" && make install)

cp "$PREFIX/bin/ffmpeg" "$PREFIX/bin/ffprobe" "$OUT/bin/"
cp ffmpeg-7.1.1/COPYING.LGPLv2.1 "$OUT/licenses/FFmpeg-COPYING.LGPLv2.1"
cp ffmpeg-7.1.1/LICENSE.md "$OUT/licenses/FFmpeg-LICENSE.md"
cp lame-3.100/COPYING "$OUT/licenses/LAME-COPYING"
cp libogg-1.3.5/COPYING "$OUT/licenses/libogg-COPYING"
cp libvorbis-1.3.7/COPYING "$OUT/licenses/libvorbis-COPYING"
cp libvpx-1.15.0/LICENSE "$OUT/licenses/libvpx-LICENSE"
cp libwebp-1.5.0/COPYING "$OUT/licenses/libwebp-COPYING"
printf '%s\n' "${SOURCES[@]}" > "$OUT/licenses/SOURCES.txt"
"$PREFIX/bin/ffmpeg" -hide_banner -buildconf > "$OUT/licenses/FFmpeg-buildconf.txt"

# Ship only binaries that depend on macOS system libraries.
for bin in "$OUT"/bin/*; do
  if otool -L "$bin" | tail -n +2 | grep -vE '^\s+(/usr/lib/|/System/Library/)'; then
    echo "$bin links a non-system library" >&2; exit 1
  fi
done
encoders="$("$OUT/bin/ffmpeg" -hide_banner -encoders)"
for name in libmp3lame libvorbis libvpx libwebp h264_videotoolbox aac flac mpeg4; do
  grep -qE "^ [^ ]+ $name " <<< "$encoders" || { echo "Missing encoder $name" >&2; exit 1; }
done
echo "Built $OUT"
