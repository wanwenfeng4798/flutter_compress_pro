import 'dart:io';

/// Owns exclusively reserved output files. Existing files are never overwritten.
abstract final class PluginCache {
  static final Set<String> _reserved = {};

  static Directory cacheDir() => Directory(
    '${Directory.systemTemp.path}${Platform.pathSeparator}flutter_compress_pro',
  )..createSync(recursive: true);

  static Future<void> clear() async {
    await for (final entity in cacheDir().list()) {
      if (_reserved.any(
        (p) =>
            p == entity.path ||
            p.startsWith('${entity.path}${Platform.pathSeparator}'),
      )) {
        continue;
      }
      try {
        await entity.delete(recursive: true);
      } on FileSystemException {
        /* In use by another process. */
      }
    }
  }

  static void release(File file) => _reserved.remove(file.absolute.path);

  static File reserve(Directory dir, String name) {
    dir.createSync(recursive: true);
    final leaf = name.split(RegExp(r'[/\\]')).last;
    if (leaf.isEmpty || leaf == '.' || leaf == '..') {
      throw ArgumentError('Invalid file name');
    }
    final dot = leaf.lastIndexOf('.');
    final base = dot > 0 ? leaf.substring(0, dot) : leaf;
    final ext = dot > 0 ? leaf.substring(dot) : '';
    for (var i = 0; i < 10000; i++) {
      final file = File(
        '${dir.path}${Platform.pathSeparator}$base${i == 0 ? '' : '-$i'}$ext',
      );
      try {
        file.createSync(exclusive: true);
        _reserved.add(file.absolute.path);
        return file;
      } on FileSystemException {
        if (FileSystemEntity.typeSync(file.path, followLinks: false) ==
            FileSystemEntityType.notFound) {
          rethrow;
        }
      }
    }
    throw FileSystemException('Unable to reserve output', dir.path);
  }

  static File resolveOutput({
    required String? outputDir,
    required String? outputName,
    required String sourcePath,
    required String ext,
  }) {
    final dir =
        (outputDir == null || outputDir.isEmpty
                ? cacheDir()
                : Directory(outputDir))
            .absolute;
    final leaf =
        (outputName == null || outputName.trim().isEmpty
                ? sourcePath
                : outputName)
            .split(RegExp(r'[/\\]'))
            .last;
    final dot = leaf.lastIndexOf('.');
    final sourceBase = dot > 0 ? leaf.substring(0, dot) : leaf;
    final base = outputName == null
        ? '${sourceBase}_${DateTime.now().microsecondsSinceEpoch}'
        : sourceBase;
    return reserve(dir, '${base.isEmpty ? 'compressed' : base}.$ext');
  }

  static Future<String> saveCopy(
    String sourcePath,
    Directory folder,
    String? name,
  ) async {
    final source = File(sourcePath);
    // Validate the source before creating anything at the destination.
    final canonical = await source.resolveSymbolicLinks();
    if (!await source.exists()) {
      throw FileSystemException('Source missing', sourcePath);
    }
    final leaf = (name ?? source.uri.pathSegments.last)
        .split(RegExp(r'[/\\]'))
        .last;
    final intended = File('${folder.path}${Platform.pathSeparator}$leaf');
    if (await intended.exists() &&
        await FileSystemEntity.identical(source.path, intended.path)) {
      return canonical;
    }
    final destination = reserve(folder, leaf);
    Directory? staging;
    try {
      staging = await folder.createTemp('.fcp-save-');
      final copied = await source.copy(
        '${staging.path}${Platform.pathSeparator}copy',
      );
      await copied.rename(destination.path);
      return destination.path;
    } catch (_) {
      await destination.delete();
      rethrow;
    } finally {
      release(destination);
      if (staging != null) await staging.delete(recursive: true);
    }
  }
}
