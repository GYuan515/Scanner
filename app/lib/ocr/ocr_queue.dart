import 'dart:async';
import 'dart:ui' show Rect;

import '../data/db.dart';
import '../data/page_store.dart';
import '../error_log.dart';
import 'ocr_result.dart';

/// What the queue needs from the OCR engine; `OcrService` implements it,
/// tests use a fake.
abstract class OcrEngine {
  Future<OcrResult> recognizeFile(String path, {Rect? region});
}

/// Reads pages in the background, one at a time.
///
/// With [auto] on, every page without text is read as soon as it appears
/// (new scans, imports, re-crops). With it off only pages passed to
/// [request] are read. Pages that fail are skipped for the rest of the
/// session so a bad image cannot make the queue spin.
class OcrQueue {
  OcrQueue(this.db, this.store, this._engine);

  final AppDatabase db;
  final PageStore store;
  final Future<OcrEngine> Function() _engine;

  bool auto = true;
  final _requested = <int>{};
  final _failed = <int>{};
  StreamSubscription<int>? _sub;
  Future<void>? _running;

  /// Set when work arrives while [_drain] is running, so it looks again
  /// before stopping instead of missing a page added during its last query.
  bool _again = false;

  /// Reads in progress, keyed by page id and image file, shared between the
  /// queue and [readNow] so one page is never read twice at the same time.
  final _inFlight = <(int, String), Future<OcrResult?>>{};

  void start() {
    _sub ??= db.watchOcrPendingCount().listen((n) {
      if (n > 0) _pump();
    });
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
  }

  /// Reads these pages even when [auto] is off, and retries failed ones.
  void request(Iterable<int> pageIds) {
    _requested.addAll(pageIds);
    _failed.removeAll(pageIds);
    _pump();
  }

  /// Resolves when the queue has nothing left to do (tests, batch export).
  Future<void> idle() async {
    while (_running != null) {
      await _running;
    }
  }

  void _pump() {
    if (_running != null) {
      _again = true;
      return;
    }
    _running = _drain().whenComplete(() => _running = null);
  }

  Future<void> _drain() async {
    try {
      do {
        _again = false;
        while (true) {
          final todo = auto
              ? await db.pagesNeedingOcr(skip: _failed)
              : await db.pagesNeedingOcr(skip: _failed, only: {..._requested});
          if (todo.isEmpty) break;
          for (final pg in todo) {
            await _read(pg);
          }
        }
      } while (_again);
    } catch (e, st) {
      // A database error must not leave an unhandled future behind.
      ErrorLog.instance?.write('ocr queue', '$e', st);
    }
  }

  Future<void> _read(ScanPage pg) async {
    try {
      await readNow(pg);
      _requested.remove(pg.id);
    } catch (e, st) {
      // A page re-cropped, retaken or deleted while it was being read lost
      // its old image file; that is not a failure of this page. It is read
      // again from the new image (or is gone).
      final now = await db.pageById(pg.id);
      if (now != null && now.processedFile == pg.processedFile) {
        _failed.add(pg.id);
        _requested.remove(pg.id);
        ErrorLog.instance?.write('ocr page ${pg.id}', '$e', st);
      }
    }
  }

  /// Reads [pg] and stores the result. Returns null when the page changed
  /// meanwhile (it stays queued for the new image) or, unless [replace],
  /// when it already had text (so a late duplicate never overwrites edits).
  /// A read already running for the same image is joined, not repeated.
  Future<OcrResult?> readNow(ScanPage pg, {bool replace = false}) {
    final key = (pg.id, pg.processedFile);
    final running = _inFlight[key];
    if (running != null && !replace) return running;
    final f = _readAndSave(pg, replace);
    _inFlight[key] = f;
    f.whenComplete(() {
      if (identical(_inFlight[key], f)) _inFlight.remove(key);
    }).ignore();
    return f;
  }

  Future<OcrResult?> _readAndSave(ScanPage pg, bool replace) async {
    final engine = await _engine();
    final result = await engine.recognizeFile(store.file(pg.processedFile).path);
    final saved = await db.saveOcr(
      pg.id,
      text: result.text,
      json: result.toJsonString(),
      processedFile: pg.processedFile,
      onlyIfEmpty: !replace,
    );
    return saved ? result : null;
  }
}
