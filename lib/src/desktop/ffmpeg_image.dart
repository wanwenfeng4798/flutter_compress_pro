import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../error_codes.dart';
import '../exceptions.dart';
import '../image_models.dart';
import '../size_math.dart';
import 'ffmpeg_binaries.dart';
import 'plugin_cache.dart';

/// Image info / compress via ffmpeg (Windows / Linux).
abstract final class FfmpegImage {
  static Future<ImageMeta> info(String path) async {
    await FfmpegBinaries.ensureAvailable();
    final result = await Process.run(FfmpegBinaries.ffprobe, [
      '-v',
      'quiet',
      '-print_format',
      'json',
      '-show_streams',
      '-show_format',
      path,
    ]);
    if (result.exitCode != 0) {
      throw ImageCompressException(
        CompressErrorCode.imageInfoFailed,
        'ffprobe failed: ${result.stderr}',
      );
    }
    final decoded = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    final streams = (decoded['streams'] as List?) ?? const [];
    Map<String, dynamic>? image;
    for (final s in streams) {
      final m = s as Map<String, dynamic>;
      if (m['codec_type'] == 'video') {
        image = m;
        break;
      }
    }
    image ??= streams.isNotEmpty ? streams.first as Map<String, dynamic> : null;
    if (image == null) {
      throw ImageCompressException(
        CompressErrorCode.imageInfoFailed,
        'No image stream in $path',
      );
    }
    final format = (decoded['format'] as Map?)?.cast<String, dynamic>() ?? {};
    final sizeBytes =
        int.tryParse('${format['size']}') ?? await File(path).length();
    final codec = '${image['codec_name'] ?? ''}'.toLowerCase();
    return ImageMeta(
      path: path,
      width: (image['width'] as num?)?.toInt() ?? 0,
      height: (image['height'] as num?)?.toInt() ?? 0,
      sizeBytes: sizeBytes,
      format: _mapCodec(codec, path),
    );
  }

  static Future<ImageCompressResult> compressFile({
    required String path,
    required ImageCompressConfig config,
    required String? outputDir,
    required String? outputName,
  }) async {
    config.validate();
    final meta = await info(path);
    final originalSize = meta.sizeBytes;
    final format = _resolveFormat(config, meta.format);
    final out = PluginCache.resolveOutput(
      outputDir: outputDir,
      outputName: outputName,
      sourcePath: path,
      ext: _extFor(format),
    );

    try {
      await _encode(
        inputPath: path,
        outputPath: out.path,
        config: config,
        format: format,
        srcW: meta.width,
        srcH: meta.height,
        keepExif: config.keepExif,
      );

      final compressedSize = await File(out.path).length();
      final dims = await _probeDims(out.path);
      final shouldSkip = SizeMath.keepsOriginal(
        compressedSize,
        originalSize,
        config.keepOriginalIfLarger,
        config.minSavingsPercent,
      );
      if (shouldSkip) {
        try {
          await File(out.path).delete();
        } catch (_) {}
        return ImageCompressResult(
          outputPath: path,
          originalSizeBytes: originalSize,
          compressedSizeBytes: originalSize,
          width: meta.width,
          height: meta.height,
          format: meta.format ?? format,
          skipped: true,
        );
      }
      return ImageCompressResult(
        outputPath: out.path,
        originalSizeBytes: originalSize,
        compressedSizeBytes: compressedSize,
        width: dims.$1,
        height: dims.$2,
        format: format == 'heic' ? 'jpeg' : format,
        skipped: false,
      );
    } catch (_) {
      if (await out.exists()) await out.delete();
      rethrow;
    } finally {
      PluginCache.release(out);
    }
  }

  static Future<ImageBytesResult> compressBytes({
    required Uint8List source,
    required ImageCompressConfig config,
  }) async {
    config.validate();
    final scratch = await PluginCache.cacheDir().createTemp('image-');
    final tmpIn = File('${scratch.path}${Platform.pathSeparator}input.img');
    try {
      await tmpIn.writeAsBytes(source, flush: true);
      final meta = await info(tmpIn.path);
      final format = _resolveFormat(config, meta.format);
      final tmpOut = File(
        '${scratch.path}${Platform.pathSeparator}output.${_extFor(format)}',
      );
      await _encode(
        inputPath: tmpIn.path,
        outputPath: tmpOut.path,
        config: config,
        format: format,
        srcW: meta.width,
        srcH: meta.height,
        keepExif: config.keepExif,
      );
      final bytes = await tmpOut.readAsBytes();
      final dims = await _probeDims(tmpOut.path);
      try {
        await tmpOut.delete();
      } catch (_) {}

      final shouldSkip = SizeMath.keepsOriginal(
        bytes.length,
        source.length,
        config.keepOriginalIfLarger,
        config.minSavingsPercent,
      );
      if (shouldSkip) {
        return ImageBytesResult(
          bytes: source,
          originalSizeBytes: source.length,
          width: meta.width,
          height: meta.height,
          format: meta.format ?? format,
          skipped: true,
        );
      }
      return ImageBytesResult(
        bytes: bytes,
        originalSizeBytes: source.length,
        width: dims.$1,
        height: dims.$2,
        format: format == 'heic' ? 'jpeg' : format,
        skipped: false,
      );
    } finally {
      try {
        await scratch.delete(recursive: true);
      } catch (_) {}
    }
  }

  static Future<void> _encode({
    required String inputPath,
    required String outputPath,
    required ImageCompressConfig config,
    required String format,
    required int srcW,
    required int srcH,
    required bool keepExif,
  }) async {
    final scratch = await PluginCache.cacheDir().createTemp('encode-');
    try {
      // Decode/orient/cap the source once before the quality search.
      final master = '${scratch.path}${Platform.pathSeparator}master.png';
      final scale = _scaleFilter(srcW, srcH, config.maxWidth, config.maxHeight);
      final decode = await Process.run(FfmpegBinaries.ffmpeg, [
        '-y',
        '-i',
        inputPath,
        if (scale != null) ...['-vf', scale],
        '-frames:v',
        '1',
        '-c:v',
        'png',
        master,
      ]);
      if (decode.exitCode != 0) {
        throw ImageCompressException(
          CompressErrorCode.imageCompressFailed,
          '${decode.stderr}',
        );
      }
      final target = config.lossless
          ? null
          : config.targetSizeKB == null
          ? null
          : config.targetSizeKB! * 1024;
      final dims = await info(master);
      var width = dims.width;
      var height = dims.height;
      for (var round = 0; round < 24; round++) {
        Future<Uint8List> encode(int quality) async {
          final result = await Process.run(FfmpegBinaries.ffmpeg, [
            '-y',
            '-i',
            master,
            '-i',
            inputPath,
            '-map',
            '0:v:0',
            ...(keepExif ? ['-map_metadata', '1'] : ['-map_metadata', '-1']),
            '-vf',
            'scale=$width:$height',
            '-frames:v',
            '1',
            ..._codecArgs(format, config, quality: quality),
            outputPath,
          ]);
          if (result.exitCode != 0) {
            throw ImageCompressException(
              CompressErrorCode.imageCompressFailed,
              '${result.stderr}',
            );
          }
          final bytes = await File(outputPath).readAsBytes();
          if (bytes.isEmpty) {
            throw ImageCompressException(
              CompressErrorCode.imageCompressFailed,
              'Empty encoded image',
            );
          }
          return bytes;
        }

        Uint8List? best;
        if (target == null || format == 'png') {
          final bytes = await encode(config.quality);
          if (target == null || bytes.length <= target) best = bytes;
        } else {
          var low = 1, high = 100;
          while (low <= high) {
            final quality = (low + high) ~/ 2;
            final bytes = await encode(quality);
            if (bytes.length <= target) {
              best = bytes;
              low = quality + 1;
            } else {
              high = quality - 1;
            }
          }
        }
        if (best != null) {
          await File(outputPath).writeAsBytes(best);
          return;
        }
        if (width == 1 && height == 1) break;
        width = (width * 0.75).floor().clamp(1, width);
        height = (height * 0.75).floor().clamp(1, height);
      }
      throw ImageCompressException(
        CompressErrorCode.imageCompressFailed,
        'Target size cannot be met by this format including metadata',
      );
    } finally {
      await scratch.delete(recursive: true);
    }
  }

  static List<String> _codecArgs(
    String format,
    ImageCompressConfig config, {
    int? quality,
  }) {
    final q = quality ?? config.quality;
    switch (format) {
      case 'png':
        return ['-c:v', 'png'];
      case 'webp':
        if (config.lossless) {
          return ['-c:v', 'libwebp', '-lossless', '1'];
        }
        return ['-c:v', 'libwebp', '-quality', '$q'];
      default:
        return [
          '-c:v',
          'mjpeg',
          '-q:v',
          '${_jpegQ(config.lossless ? 100 : q)}',
        ];
    }
  }

  static Future<(int, int)> _probeDims(String path) async {
    try {
      final meta = await info(path);
      return (meta.width, meta.height);
    } catch (_) {
      return (0, 0);
    }
  }

  static String? _scaleFilter(int w, int h, int? maxW, int? maxH) {
    if (w <= 0 || h <= 0) return null;
    if (maxW == null && maxH == null) return null;
    var tw = w.toDouble();
    var th = h.toDouble();
    if (maxW != null && tw > maxW) {
      final s = maxW / tw;
      tw *= s;
      th *= s;
    }
    if (maxH != null && th > maxH) {
      final s = maxH / th;
      tw *= s;
      th *= s;
    }
    final rw = tw.round();
    final rh = th.round();
    if (rw == w && rh == h) return null;
    return 'scale=${rw.clamp(1, w)}:${rh.clamp(1, h)}';
  }

  static String _resolveFormat(ImageCompressConfig config, String? source) {
    if (config.format != null) {
      return switch (config.format!) {
        ImageFormat.jpeg => 'jpeg',
        ImageFormat.png => 'png',
        ImageFormat.webp => 'webp',
        ImageFormat.heic => 'heic',
      };
    }
    return source == 'png' || source == 'webp' ? source! : 'jpeg';
  }

  static String _extFor(String format) => switch (format) {
    'png' => 'png',
    'webp' => 'webp',
    'heic' => 'jpg',
    _ => 'jpg',
  };

  static String? _mapCodec(String codec, String path) {
    if (codec.contains('mjpeg') || codec == 'jpeg') return 'jpeg';
    if (codec.contains('png')) return 'png';
    if (codec.contains('webp')) return 'webp';
    if (codec.contains('hevc') || codec.contains('heic')) return 'heic';
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'png';
    if (lower.endsWith('.webp')) return 'webp';
    if (lower.endsWith('.heic') || lower.endsWith('.heif')) return 'heic';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'jpeg';
    return codec.isEmpty ? null : codec;
  }

  static int _jpegQ(int quality) =>
      (31 - (quality.clamp(1, 100) / 100.0 * 29)).round().clamp(2, 31);
}
