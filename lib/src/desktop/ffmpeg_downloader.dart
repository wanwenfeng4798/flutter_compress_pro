import 'dart:ffi';
import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';

import '../error_codes.dart';
import '../exceptions.dart';

/// Paths to resolved ffmpeg / ffprobe executables.
class FfmpegPaths {
  const FfmpegPaths({required this.ffmpeg, required this.ffprobe});
  final String ffmpeg;
  final String ffprobe;
}

/// Downloads and caches GPL FFmpeg static builds (BtbN/FFmpeg-Builds).
///
/// GPL is required for `libx264` / `libx265` (our H.264 / H.265 encoders).
/// First successful call stores binaries under the user cache dir; later runs
/// reuse them. Not used on Android / iOS / macOS / Web.
///
/// Apps that redistribute the downloaded binaries must comply with the FFmpeg
/// GPL. Prefer a system LGPL/GPL install via PATH if you need a different
/// license posture. Set `FLUTTER_COMPRESS_PRO_NO_FFMPEG_DOWNLOAD=1` to forbid fetch.
abstract final class FfmpegDownloader {
  /// Pin deliberately — bump when upgrading the downloaded FFmpeg build.
  /// Assets come from https://github.com/BtbN/FFmpeg-Builds/releases
  static const releaseTag = 'autobuild-2026-10-16-13-04';
  static const buildId = 'N-127579-g5cb9fcd211';

  /// `gpl` includes libx264/libx265; `lgpl` would not encode H.264/H.265.
  static const licenseVariant = 'gpl';

  static Directory cacheRoot() {
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        Directory.systemTemp.path;
    final dir = Directory(
      '$home${Platform.pathSeparator}.cache'
      '${Platform.pathSeparator}flutter_compress_pro'
      '${Platform.pathSeparator}ffmpeg'
      '${Platform.pathSeparator}$buildId-${Abi.current()}',
    );
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  static Future<FfmpegPaths?> cachedBinaries() async {
    final root = Directory(
      '${cacheRoot().path}${Platform.pathSeparator}installed',
    );
    final ffmpeg = File(_binPath(root, 'ffmpeg'));
    final ffprobe = File(_binPath(root, 'ffprobe'));
    final manifest = File(
      '${root.path}${Platform.pathSeparator}integrity.json',
    );
    if (!await manifest.exists() ||
        !await ffmpeg.exists() ||
        !await ffprobe.exists()) {
      return null;
    }
    try {
      final hashes = jsonDecode(await manifest.readAsString()) as Map;
      for (final file in [ffmpeg, ffprobe]) {
        if ((await sha256.bind(file.openRead()).first).toString() !=
            hashes[file.uri.pathSegments.last]) {
          return null;
        }
      }
      return FfmpegPaths(ffmpeg: ffmpeg.path, ffprobe: ffprobe.path);
    } catch (_) {
      return null;
    }
  }

  static const archiveHashes = {
    'linux64':
        '3d994f31aa9ee78ef56eab530a86d50d8307200cb9d1788be36c1ea9410e605c',
    'linuxarm64':
        '56c9cd900daa38fd07eaab8e144e577fe637293d376a0b33de21364923a90709',
    'win64': 'b7c94a054ae4c1cce0e11ae18979d932e6f129ba6f5253b328227b31f1bf2bbf',
    'winarm64':
        '3b77967d7ce8102d288cb9443227b344156d97edd97a18acd7819806f5faa932',
  };

  static Future<FfmpegPaths> download() async {
    final root = cacheRoot();
    final lock = await File(
      '${root.path}${Platform.pathSeparator}install.lock',
    ).open(mode: FileMode.append);
    await lock.lock(FileLock.blockingExclusive);
    Directory? scratch;
    try {
      final cached = await cachedBinaries();
      if (cached != null) return cached;
      scratch = await root.createTemp('download-');
      final asset = _assetName();
      final url =
          'https://github.com/BtbN/FFmpeg-Builds/releases/download/$releaseTag/$asset';
      final archive = File('${scratch.path}${Platform.pathSeparator}$asset');
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 30);
      try {
        final response = await (await client.getUrl(Uri.parse(url))).close();
        if (response.statusCode != 200) {
          throw HttpException(
            'FFmpeg HTTP ${response.statusCode}',
            uri: Uri.parse(url),
          );
        }
        await response
            .timeout(const Duration(minutes: 2))
            .pipe(archive.openWrite());
      } finally {
        client.close(force: true);
      }
      final platform = archiveHashes.keys.singleWhere(
        (key) => asset.contains('-$key-'),
      );
      final digest = (await sha256.bind(archive.openRead()).first).toString();
      if (digest != archiveHashes[platform]) {
        throw const FormatException('FFmpeg archive SHA-256 mismatch');
      }
      await _extract(archive.path, scratch);
      final bin = await _findBinDir(scratch);
      if (bin == null) {
        throw const FormatException('FFmpeg archive has no bin directory');
      }
      final install = await scratch.createTemp('install-');
      final hashes = <String, String>{};
      for (final name in ['ffmpeg', 'ffprobe']) {
        final executable = Platform.isWindows ? '$name.exe' : name;
        final file = await File(
          '${bin.path}${Platform.pathSeparator}$executable',
        ).copy(_binPath(install, name));
        await _chmodX(file.path);
        hashes[executable] = (await sha256.bind(file.openRead()).first)
            .toString();
      }
      await File(
        '${install.path}${Platform.pathSeparator}integrity.json',
      ).writeAsString(jsonEncode(hashes), flush: true);
      final destination = Directory(
        '${root.path}${Platform.pathSeparator}installed',
      );
      if (await destination.exists()) await destination.delete(recursive: true);
      await install.rename(destination.path);
      return FfmpegPaths(
        ffmpeg: _binPath(destination, 'ffmpeg'),
        ffprobe: _binPath(destination, 'ffprobe'),
      );
    } finally {
      if (scratch != null && await scratch.exists()) {
        await scratch.delete(recursive: true);
      }
      await lock.unlock();
      await lock.close();
    }
  }

  static String _binPath(Directory root, String name) {
    final exe = Platform.isWindows ? '$name.exe' : name;
    return '${root.path}${Platform.pathSeparator}$exe';
  }

  static String _assetName() {
    final abi = Abi.current();
    if (Platform.isWindows) {
      if (abi == Abi.windowsX64) {
        return 'ffmpeg-$buildId-win64-$licenseVariant.zip';
      }
      if (abi == Abi.windowsArm64) {
        return 'ffmpeg-$buildId-winarm64-$licenseVariant.zip';
      }
      throw VideoCompressException(
        CompressErrorCode.unsupported,
        'No auto-download FFmpeg build for Windows ABI $abi. '
        'Install FFmpeg or set FLUTTER_COMPRESS_PRO_FFMPEG.',
      );
    }
    if (Platform.isLinux) {
      if (abi == Abi.linuxX64) {
        return 'ffmpeg-$buildId-linux64-$licenseVariant.tar.xz';
      }
      if (abi == Abi.linuxArm64) {
        return 'ffmpeg-$buildId-linuxarm64-$licenseVariant.tar.xz';
      }
      throw VideoCompressException(
        CompressErrorCode.unsupported,
        'No auto-download FFmpeg build for Linux ABI $abi. '
        'Install FFmpeg or set FLUTTER_COMPRESS_PRO_FFMPEG.',
      );
    }
    throw VideoCompressException(
      CompressErrorCode.unsupported,
      'FFmpeg auto-download is only for Windows/Linux',
    );
  }

  static Future<void> _extract(String archivePath, Directory dest) async {
    if (archivePath.endsWith('.zip')) {
      // Prefer tar (Windows 10+ / bsdtar) then PowerShell.
      ProcessResult? tar;
      try {
        tar = await Process.run('tar', ['-xf', archivePath, '-C', dest.path]);
      } on ProcessException {
        /* Use PowerShell when tar is absent. */
      }
      if (tar?.exitCode == 0) return;
      final ps = await Process.run(
        'powershell',
        [
          '-NoProfile',
          '-Command',
          r'Expand-Archive -LiteralPath $env:FCP_ARCHIVE -DestinationPath $env:FCP_DEST -Force',
        ],
        environment: {'FCP_ARCHIVE': archivePath, 'FCP_DEST': dest.path},
      );
      if (ps.exitCode != 0) {
        throw VideoCompressException(
          CompressErrorCode.unsupported,
          'Failed to extract FFmpeg zip (tar: ${tar?.stderr}; powershell: ${ps.stderr})',
        );
      }
      return;
    }
    // .tar.xz
    final result = await Process.run('tar', [
      '-xJf',
      archivePath,
      '-C',
      dest.path,
    ]);
    if (result.exitCode != 0) {
      throw VideoCompressException(
        CompressErrorCode.unsupported,
        'Failed to extract FFmpeg archive: ${result.stderr}',
      );
    }
  }

  static Future<Directory?> _findBinDir(Directory root) async {
    final direct = Directory('${root.path}${Platform.pathSeparator}bin');
    if (await direct.exists()) return direct;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is Directory &&
          entity.path.endsWith('${Platform.pathSeparator}bin')) {
        return entity;
      }
    }
    return null;
  }

  static Future<void> _chmodX(String path) async {
    if (Platform.isWindows) return;
    try {
      await Process.run('chmod', ['+x', path]);
    } catch (_) {}
  }
}
