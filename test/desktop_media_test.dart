import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter_compress_pro/flutter_compress_pro.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final enabled = Platform.environment['FCP_RUN_MEDIA_TESTS'] == '1';
  final backend = FlutterCompressDesktop();
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('fcp-media-');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test(
    'real FFmpeg preserves duration, reports silent input and caps fps without upsampling',
    () async {
      final source = File('example/assets/sample.mp4').absolute;
      final before = await source.readAsBytes();
      final result = await backend.compress(
        'video',
        source.path,
        const VideoCompressConfig(
          codec: VideoCodec.h264,
          frameRate: 30,
          maxWidth: 320,
          videoBitrateKbps: 200,
          keepOriginalIfLarger: false,
        ),
        directory.path,
        'video',
      );
      expect(result.skipped, isFalse);
      expect(result.durationMs, closeTo(4000, 200));
      expect(result.hasAudio, isFalse);
      expect(result.frameRate, lessThanOrEqualTo(24.1));
      expect(result.width, 320);
      expect(
        result.compressedSizeBytes,
        await File(result.outputPath).length(),
      );
      expect(await source.readAsBytes(), before);
      final trimmed = await backend.compress(
        'trim',
        source.path,
        const VideoCompressConfig(
          codec: VideoCodec.h264,
          trim: TrimRange(startMs: 1000, endMs: 99999),
          maxWidth: 320,
          keepOriginalIfLarger: false,
        ),
        directory.path,
        'trim',
      );
      expect(trimmed.durationMs, closeTo(3000, 200));
    },
    skip: !enabled,
  );

  test(
    'real JPEG, PNG and WebP searches return outputs below the requested target',
    () async {
      final pixels = Uint8List(256 * 256 * 4);
      var seed = 12345;
      for (var i = 0; i < pixels.length; i += 4) {
        seed = (seed * 1664525 + 1013904223) & 0xffffffff;
        pixels[i] = seed & 255;
        pixels[i + 1] = (seed >> 8) & 255;
        pixels[i + 2] = (seed >> 16) & 255;
        pixels[i + 3] = 255;
      }
      final decoded = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        pixels,
        256,
        256,
        ui.PixelFormat.rgba8888,
        decoded.complete,
      );
      final image = await decoded.future;
      final png = (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List();
      image.dispose();
      final source = File('${directory.path}/source.png');
      await source.writeAsBytes(png);
      for (final format in [
        ImageFormat.jpeg,
        ImageFormat.png,
        ImageFormat.webp,
      ]) {
        final result = await backend.compressImage(
          source.path,
          ImageCompressConfig(
            format: format,
            targetSizeKB: 5,
            keepOriginalIfLarger: false,
          ),
          directory.path,
          format.name,
        );
        expect(result.skipped, isFalse);
        expect(result.compressedSizeBytes, inInclusiveRange(1, 5 * 1024));
        expect(result.width, greaterThan(0));
        expect(result.height, greaterThan(0));
        final bytes = await backend.compressImageBytes(
          png,
          ImageCompressConfig(
            format: format,
            targetSizeKB: 5,
            keepOriginalIfLarger: false,
          ),
        );
        expect(bytes.bytes.length, inInclusiveRange(1, 5 * 1024));
      }
      final bmp = '${directory.path}/source.bmp';
      final converted = await Process.run(
        Platform.environment['FLUTTER_COMPRESS_PRO_FFMPEG'] ?? 'ffmpeg',
        ['-y', '-i', source.path, bmp],
      );
      expect(converted.exitCode, 0);
      final fallback = await backend.compressImage(
        bmp,
        const ImageCompressConfig(keepOriginalIfLarger: false),
        directory.path,
        'fallback',
      );
      expect(fallback.format, 'jpeg');
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
