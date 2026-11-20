# Changelog

## 0.2.2

- Update example dependencies (file_picker 13.4.0, material_ui 1.11.1 and transitive packages), the vendored MP4Box (2.5.0), the example Gradle wrapper (9.9.2) and CI (Flutter 3.50.0, setup-java 6.3.0).
- Fix desktop (FFmpeg) handling of rotated sources: read the `displaymatrix` rotation as well as the legacy `rotate` tag and report the displayed size, so portrait clips are no longer scaled with landscape dimensions.
- Web: add `trim`, `frameRate` cap and AAC-LC audio passthrough (`removeAudio` honoured); bitrate budget accounts for the copied audio.
- Android: add `frameRate` cap (Media3 `FrameDropEffect`) and `audioBitrateKbps` (audio encoder settings).
- Fix Android probing of rotated sources: report the displayed (rotated) width/height so resolution caps and size estimates match what Media3 renders.

## 0.2.1

- Update dependencies, Android build tools, and the vendored MP4Box library.
- Fix cross-platform cancellation, concurrent job handling, cache protection, and safe output file creation.
- Correct Apple video scaling and byte-channel results, Web timing and queue backpressure, and desktop image target-size searches.
- Verify FFmpeg downloads with pinned builds and SHA-256 checks; add native, browser, desktop media, and Wasm regression coverage.

## 0.2.0

- Bump Android / example dependencies (Media3 1.11.1, AGP 9.4.1, Kotlin 2.4.20, Gradle 9.8.0, and latest pub packages).

## 0.1.0

Initial release of **flutter_compress_pro**.

### Platforms

- **Android** — Media3 Transformer (no FFmpeg)
- **iOS / macOS** — shared AVFoundation / ImageIO under `darwin/` (`sharedDarwinSource`)
- **Web** — WebCodecs + Canvas (no FFmpeg)
- **Windows / Linux** — FFmpeg via system `PATH`, or auto-download (BtbN GPL) on first use

### Video

- Target size / bitrate / quality % / presets
- H.264 and HEVC (H.265) with automatic H.264 fallback
- Resolution cap, trim, remove audio, audio bitrate (where the engine supports it)
- Thumbnail, media info, size estimate, progress, cancel, batch

### Image

- Target size / quality / lossless
- JPEG · PNG · WebP · HEIC (with platform fallbacks)
- Resolution cap, optional EXIF keep, `compressImageBytes`

### Notes

- Windows / Linux FFmpeg: override with `FLUTTER_COMPRESS_PRO_FFMPEG` /
  `FLUTTER_COMPRESS_PRO_FFPROBE`; disable fetch with
  `FLUTTER_COMPRESS_PRO_NO_FFMPEG_DOWNLOAD=1`.
- Auto-downloaded FFmpeg binaries are GPL (third-party); the Dart package itself
  remains MIT.
