# QuickConvert for macOS

Drag a file onto the QuickConvert menu bar icon, keep dragging onto a format in the tray that opens, and release to convert. Images, PDFs, audio and video; everything runs inside the app with bundled engines, no Terminal and no extra installs.

**Status: pre-release.** Not yet tested on a real Mac. CI builds the app and runs every conversion path on Apple Silicon and Intel runners.

## Build (macOS 14+, Xcode 16)

```bash
scripts/build-ffmpeg.sh   # once per architecture, outputs vendor/ffmpeg-<arch>
ARCHS="$(uname -m)" scripts/package.sh
dist/QuickConvert.app/Contents/MacOS/QuickConvert --self-test
```

The DMG is ad hoc signed, not notarized: on first launch, open **System Settings → Privacy & Security** and choose **Open Anyway** for QuickConvert.

Bundled FFmpeg is built LGPL-only from pinned upstream sources; licenses ship in `QuickConvert.app/Contents/Resources/Licenses`.
