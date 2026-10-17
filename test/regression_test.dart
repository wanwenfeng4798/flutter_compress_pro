import 'dart:async';
import 'dart:io';
import 'package:flutter_compress_pro/flutter_compress_pro.dart';
import 'package:flutter_compress_pro/flutter_compress_pro_platform_interface.dart';
import 'package:flutter_compress_pro/src/desktop/plugin_cache.dart';
import 'package:flutter_test/flutter_test.dart';

class ControlledPlatform extends FlutterCompressPlatform {
  final calls = <String>[];
  final pending = <Completer<VideoCompressResult>>[];
  final events = StreamController<CompressionProgress>.broadcast();
  @override
  Stream<CompressionProgress> get progressStream => events.stream;
  @override
  Future<VideoCompressResult> compress(
    String id,
    String path,
    VideoCompressConfig config,
    String? directory,
    String? name,
  ) {
    calls.add(path);
    final completer = Completer<VideoCompressResult>();
    pending.add(completer);
    return completer.future;
  }

  @override
  Future<void> cancel(String? id) async {
    pending.last.completeError(VideoCompressCancelledException());
  }

  @override
  Future<void> clearCache() async {}
  void finish(int index) => pending[index].complete(
    const VideoCompressResult(
      id: 'test',
      outputPath: 'output',
      originalSizeBytes: 100,
      compressedSizeBytes: 50,
      width: 16,
      height: 16,
      durationMs: 1000,
      codec: 'h264',
      skipped: false,
    ),
  );
}

void main() {
  final api = FlutterCompress.instance;
  test(
    'concurrent calls serialize; cancelling a queued job cannot cancel its predecessor',
    () async {
      final backend = ControlledPlatform();
      FlutterCompressPlatform.instance = backend;
      final first = api.compress('first', const VideoCompressConfig());
      final token = CancellationToken();
      final second = api.compress(
        'second',
        const VideoCompressConfig(),
        cancellationToken: token,
      );
      final secondCheck = expectLater(
        second,
        throwsA(isA<CompressCancelled>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(backend.calls, ['first']);
      await token.cancel();
      backend.finish(0);
      await first;
      await secondCheck;
      expect(backend.calls, ['first']);
      await backend.events.close();
    },
  );
  test(
    'cache deletion is rejected while an encode is pending; final progress reaches one',
    () async {
      final backend = ControlledPlatform();
      FlutterCompressPlatform.instance = backend;
      final progress = <double>[];
      final pending = api.compress(
        'first',
        const VideoCompressConfig(),
        onProgress: (p) => progress.add(p.progress),
      );
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        api.clearCache(),
        throwsA(isA<VideoCompressException>()),
      );
      backend.finish(0);
      await pending;
      expect(progress.last, 1);
      await api.clearCache();
      await backend.events.close();
    },
  );
  test(
    'preset parameters are checked at runtime before reaching a backend',
    () async {
      await expectLater(
        api.compress(
          'input',
          const VideoCompressConfig.forSocialMedia(maxWidth: -1),
        ),
        throwsA(isA<VideoCompressException>()),
      );
      expect(
        () => const VideoCompressConfig(frameRate: double.infinity).validate(),
        throwsA(isA<VideoCompressException>()),
      );
      expect(
        () => const ImageCompressConfig.forAvatar(maxHeight: -1).validate(),
        throwsA(isA<ImageCompressException>()),
      );
    },
  );
  test(
    'tiny caps never enlarge a source and none keeps exact odd dimensions',
    () {
      expect(
        SizeMath.targetDimensions(8, 8, const VideoCompressConfig(maxWidth: 4)),
        (4, 4),
      );
      expect(
        SizeMath.targetDimensions(
          9,
          7,
          const VideoCompressConfig(
            maxWidth: 9,
            alignment: DimensionAlignment.none,
          ),
        ),
        (9, 7),
      );
    },
  );
  test(
    'exclusive outputs survive aliases, existing suffixes and parallel requests',
    () async {
      final dir = await Directory.systemTemp.createTemp('fcp-safety-');
      addTearDown(() => dir.delete(recursive: true));
      final source = File('${dir.path}/photo.jpg')
        ..writeAsStringSync('original');
      File('${dir.path}/photo-1.jpg').writeAsStringSync('existing');
      final child = Directory('${dir.path}/child')..createSync();
      final reserved = List.generate(
        3,
        (_) => PluginCache.resolveOutput(
          outputDir: '${child.path}/..',
          outputName: 'photo',
          sourcePath: source.path,
          ext: 'jpg',
        ),
      );
      expect(reserved.map((f) => f.path).toSet(), hasLength(3));
      expect(await source.readAsString(), 'original');
      expect(await File('${dir.path}/photo-1.jpg').readAsString(), 'existing');
      for (final file in reserved) {
        PluginCache.release(file);
      }
    },
  );
  test(
    'saving onto self or a symlink preserves source; collisions preserve destination',
    () async {
      final dir = await Directory.systemTemp.createTemp('fcp-save-');
      addTearDown(() => dir.delete(recursive: true));
      final source = File('${dir.path}/source.jpg')
        ..writeAsStringSync('original');
      expect(
        await PluginCache.saveCopy(source.path, dir, 'source.jpg'),
        await source.resolveSymbolicLinks(),
      );
      if (!Platform.isWindows) {
        await Link('${dir.path}/alias.jpg').create(source.path);
        await PluginCache.saveCopy(source.path, dir, 'alias.jpg');
      }
      File('${dir.path}/destination.jpg').writeAsStringSync('keep');
      final saved = await PluginCache.saveCopy(
        source.path,
        dir,
        'destination.jpg',
      );
      expect(await File(saved).readAsString(), 'original');
      expect(await File('${dir.path}/destination.jpg').readAsString(), 'keep');
      expect(await source.readAsString(), 'original');
    },
  );
}
