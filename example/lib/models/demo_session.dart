import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_compress_pro/flutter_compress_pro.dart';

/// Common lifetime and output ownership for both compression demos.
mixin DemoSession<T extends StatefulWidget> on State<T> {
  final _outputs = <String>{};
  int inputRevision = 0;

  @override
  void setState(VoidCallback fn) {
    if (mounted) super.setState(fn);
  }

  String prependLog(String current, String line) =>
      '$line\n$current'.split('\n').take(200).join('\n');

  Future<void> ownOutput(String path, {required bool skipped}) async {
    if (skipped) return;
    if (!mounted) {
      await FlutterCompress.instance.releaseOutput(path);
      return;
    }
    if (kIsWeb) _outputs.add(path);
  }

  Future<String> saveOutput(String path, {String? fileName}) async {
    try {
      return await FlutterCompress.instance.saveToDownloads(
        path,
        fileName: fileName,
      );
    } finally {
      if (kIsWeb) {
        // The browser download helper waits until the download can consume it.
        _outputs.remove(path);
        await FlutterCompress.instance.releaseOutput(path);
      }
    }
  }

  @override
  void dispose() {
    for (final path in _outputs) {
      unawaited(FlutterCompress.instance.releaseOutput(path));
    }
    super.dispose();
  }
}
