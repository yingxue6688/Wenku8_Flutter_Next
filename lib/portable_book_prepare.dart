import 'dart:io';
import 'package:flutter/services.dart';

typedef PreparedBookDocument = ({String name, String? path, String? error});

class PortableBookPreparer {
  PortableBookPreparer({
    required this.directory,
    required this.textCodecToken,
    required this.decodeNames,
    required this.convert,
    required this.extractKindle,
    this.extractPdf,
  });

  final Directory directory;
  final RootIsolateToken textCodecToken;
  final Future<List<String>> Function(List<String> names) decodeNames;
  final Future<List<PreparedBookDocument>> Function(String name, String path)
  convert;
  final Future<int> Function(String source, String output) extractKindle;
  final Future<void> Function(String name, String source, String output)?
  extractPdf;

  static Future<void> clearPreviousRuns(Directory directory) async {
    try {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } catch (_) {}
  }

  Future<List<PreparedBookDocument>> prepare(String name, String path) =>
      convert(name, path);

  Future<void> releasePaths(Iterable<String> paths) async {
    for (final item in paths) {
      try {
        final file = File(item);
        if (await file.exists() && file.path.startsWith(directory.path)) {
          await file.delete();
        }
      } catch (_) {}
    }
  }
}
