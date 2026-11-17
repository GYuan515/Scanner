import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Temporary copies of documents (reader PDFs, files handed to the share
/// sheet). They are plain, unredacted renderings, so they must go when
/// the document is redacted, locked or deleted.
class TempFiles {
  static Future<Directory> dir(String name) async {
    final d = Directory(p.join((await getTemporaryDirectory()).path, name));
    await d.create(recursive: true);
    return d;
  }

  /// Reader cache file for a document state.
  static Future<File> readerFile(int docId, String key) async =>
      File(p.join((await dir('reader')).path, 'doc${docId}_$key.pdf'));

  /// Deletes every cached rendering of [docId] and all share-sheet copies
  /// (their names come from titles, so they cannot be told apart).
  static Future<void> forgetDocument(int docId) async {
    try {
      for (final f in (await dir('reader')).listSync().whereType<File>()) {
        if (p.basename(f.path).startsWith('doc${docId}_')) await _delete(f);
      }
      for (final f in (await dir('export')).listSync().whereType<File>()) {
        await _delete(f);
      }
    } catch (_) {
      // Best effort (and no temp directory in unit tests): a leftover temp
      // file is not worth failing the redaction or deletion.
    }
  }

  static Future<void> _delete(File f) async {
    try {
      await f.delete();
    } on FileSystemException {
      // Already gone or in use; the OS clears temp eventually.
    }
  }
}
