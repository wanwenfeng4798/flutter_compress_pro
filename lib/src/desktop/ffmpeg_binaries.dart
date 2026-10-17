import 'dart:async';
import 'dart:io';

import '../error_codes.dart';
import '../exceptions.dart';
import 'ffmpeg_downloader.dart';

/// Resolves `ffmpeg` / `ffprobe` for Windows & Linux.
///
/// Order: env override → PATH → previously downloaded cache → auto-download
/// (GPL static build from BtbN/FFmpeg-Builds, for libx264/libx265). Set
/// `FLUTTER_COMPRESS_PRO_NO_FFMPEG_DOWNLOAD=1` to disable network fetch.
abstract final class FfmpegBinaries {
  static String? _resolvedFfmpeg;
  static String? _resolvedFfprobe;
  static Future<void>? _ensureFuture;

  static String get ffmpeg =>
      _resolvedFfmpeg ??
      Platform.environment['FLUTTER_COMPRESS_PRO_FFMPEG'] ??
      'ffmpeg';

  static String get ffprobe =>
      _resolvedFfprobe ??
      Platform.environment['FLUTTER_COMPRESS_PRO_FFPROBE'] ??
      'ffprobe';

  static Future<void> ensureAvailable({bool allowDownload = true}) async {
    if (!allowDownload) {
      await _ensureAvailableImpl(allowDownload: false);
      return;
    }
    final pending = _ensureFuture ??= _ensureAvailableImpl();
    try {
      await pending;
    } catch (_) {
      if (identical(_ensureFuture, pending)) _ensureFuture = null;
      rethrow;
    }
  }

  static Future<void> _ensureAvailableImpl({bool allowDownload = true}) async {
    try {
      final envFfmpeg = Platform.environment['FLUTTER_COMPRESS_PRO_FFMPEG'];
      final envFfprobe = Platform.environment['FLUTTER_COMPRESS_PRO_FFPROBE'];
      final candidateFfmpeg = envFfmpeg?.isNotEmpty == true
          ? envFfmpeg!
          : 'ffmpeg';
      final candidateProbe = envFfprobe?.isNotEmpty == true
          ? envFfprobe!
          : 'ffprobe';
      if (await _works(candidateFfmpeg) && await _works(candidateProbe)) {
        _resolvedFfmpeg = candidateFfmpeg;
        _resolvedFfprobe = candidateProbe;
        return;
      }
      if (envFfmpeg?.isNotEmpty == true || envFfprobe?.isNotEmpty == true) {
        throw VideoCompressException(
          CompressErrorCode.unsupported,
          'Configured FFmpeg or FFprobe is unavailable',
        );
      }

      final cached = await FfmpegDownloader.cachedBinaries();
      if (cached != null) {
        await _verify(cached.ffmpeg, cached.ffprobe);
        _resolvedFfmpeg = cached.ffmpeg;
        _resolvedFfprobe = cached.ffprobe;
        return;
      }

      final noDownload =
          !allowDownload ||
          Platform.environment['FLUTTER_COMPRESS_PRO_NO_FFMPEG_DOWNLOAD'] ==
              '1';
      if (noDownload) {
        throw VideoCompressException(
          CompressErrorCode.unsupported,
          'FFmpeg not found on PATH and auto-download is disabled '
          '(FLUTTER_COMPRESS_PRO_NO_FFMPEG_DOWNLOAD=1). Install FFmpeg or unset '
          'that env var.',
        );
      }

      final downloaded = await FfmpegDownloader.download();
      await _verify(downloaded.ffmpeg, downloaded.ffprobe);
      _resolvedFfmpeg = downloaded.ffmpeg;
      _resolvedFfprobe = downloaded.ffprobe;
    } catch (e) {
      if (e is CompressException) rethrow;
      throw VideoCompressException(
        CompressErrorCode.unsupported,
        'Could not locate or download FFmpeg ($e). Install system FFmpeg, '
        'set FLUTTER_COMPRESS_PRO_FFMPEG / FLUTTER_COMPRESS_PRO_FFPROBE, or allow '
        'network so the plugin can download a GPL FFmpeg build '
        '(includes libx264/libx265).',
      );
    }
  }

  static Future<bool> _works(String bin) async {
    try {
      final result = await Process.run(bin, ['-version']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _verify(String ffmpegPath, String ffprobePath) async {
    for (final bin in [ffmpegPath, ffprobePath]) {
      final result = await Process.run(bin, ['-version']);
      if (result.exitCode != 0) {
        throw VideoCompressException(
          CompressErrorCode.unsupported,
          '`$bin` exited ${result.exitCode}',
        );
      }
    }
  }
}
