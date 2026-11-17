import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doc_scanner/data/db.dart';
import 'package:doc_scanner/data/page_store.dart';
import 'package:doc_scanner/ocr/ocr_queue.dart';
import 'package:doc_scanner/ocr/ocr_result.dart';
import 'package:doc_scanner/scan/image_ops.dart';
import 'package:doc_scanner/scan/quad.dart';

class FakeEngine implements OcrEngine {
  final calls = <String>[];
  bool fail = false;
  Future<void> Function(String path)? during;

  @override
  Future<OcrResult> recognizeFile(String path, {Rect? region}) async {
    calls.add(path);
    await during?.call(path);
    if (fail) throw Exception('boom');
    return OcrResult(width: 10, height: 10, rows: [
      [OcrLine(const [Offset(0, 0), Offset(5, 0), Offset(5, 2), Offset(0, 2)], '第${calls.length}次', 0.9)],
    ]);
  }
}

void main() {
  late AppDatabase db;
  late Directory tmp;
  late PageStore store;
  late FakeEngine engine;
  late OcrQueue queue;
  late List<int> jpeg;

  setUpAll(() => jpeg = File('test/fixtures/ocr_page.jpg').readAsBytesSync());

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    tmp = Directory.systemTemp.createTempSync('scanner_ocr_');
    store = PageStore(db, tmp);
    engine = FakeEngine();
    queue = OcrQueue(db, store, () async => engine);
  });

  tearDown(() async {
    await queue.dispose();
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  Future<int> newDoc({int pages = 2}) async {
    final drafts = [
      for (var i = 0; i < pages; i++)
        DraftPage(original: Uint8List.fromList(jpeg), width: 1240, height: 1754, filter: ScanFilter.original),
    ];
    return store.createDocument('文档', drafts);
  }

  Future<void> settle() async {
    // Let the pending-count stream fire, then wait for the queue.
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await queue.idle();
    }
  }

  test('auto mode reads new pages and stores text and boxes', () async {
    queue.start();
    final doc = await newDoc();
    await settle();
    final pages = await db.pagesOf(doc);
    expect(engine.calls, hasLength(2));
    for (final pg in pages) {
      expect(pg.ocrText, startsWith('第'));
      expect(OcrResult.fromJsonString(pg.ocrJson!).lines.single.box[1], const Offset(5, 0));
    }
    expect(await db.watchOcrPendingCount().first, 0);
    // Search finds documents by their recognized text.
    expect((await db.search('第1次')).map((d) => d.id), [doc]);
  });

  test('a failing page is skipped, not retried in a loop; request() retries it', () async {
    engine.fail = true;
    queue.start();
    await newDoc(pages: 1);
    await settle();
    expect(engine.calls, hasLength(1));
    expect(await db.watchOcrPendingCount().first, 1);

    engine.fail = false;
    final pg = (await db.pagesNeedingOcr()).single;
    queue.request([pg.id]);
    await settle();
    expect(engine.calls, hasLength(2));
    expect((await db.pageById(pg.id))!.ocrText, '第2次');
  });

  test('with auto off only requested pages are read', () async {
    queue
      ..auto = false
      ..start();
    final doc = await newDoc();
    await settle();
    expect(engine.calls, isEmpty);
    final pages = await db.pagesOf(doc);
    queue.request([pages.first.id]);
    await settle();
    expect(engine.calls, hasLength(1));
    expect((await db.pageById(pages.first.id))!.ocrJson, isNotNull);
    expect((await db.pageById(pages.last.id))!.ocrJson, isNull);
  });

  test('a page re-rendered while being read is read again from the new image', () async {
    queue.start();
    final doc = await newDoc(pages: 1);
    final pg = (await db.pagesOf(doc)).single;
    var first = true;
    engine.during = (_) async {
      if (!first) return;
      first = false;
      // Simulate a filter change landing mid-read.
      await (db.update(db.pages)..where((t) => t.id.equals(pg.id)))
          .write(const PagesCompanion(processedFile: Value('other.jpg')));
    };
    await settle();
    expect(engine.calls, hasLength(2));
    expect(engine.calls.last, endsWith('other.jpg'));
    expect((await db.pageById(pg.id))!.ocrText, '第2次');
  });

  test('re-cropping clears the text, changing the filter keeps it', () async {
    queue.start();
    final doc = await newDoc(pages: 1);
    await settle();
    var pg = (await db.pagesOf(doc)).single;
    expect(pg.ocrText, isNotNull);

    await store.updatePage(pg, filter: ScanFilter.grayscale);
    pg = (await db.pagesOf(doc)).single;
    expect(pg.ocrText, '第1次');

    queue.auto = false; // keep the cleared state observable
    await store.updatePage(pg, quad: const Quad(Offset(10, 10), Offset(1200, 10), Offset(1200, 1700), Offset(10, 1700)));
    pg = (await db.pagesOf(doc)).single;
    expect(pg.ocrText, isNull);
    expect(pg.ocrJson, isNull);
  });

  test('a read that fails because the page was re-rendered is retried, not marked failed', () async {
    queue.start();
    final doc = await newDoc(pages: 1);
    final pg = (await db.pagesOf(doc)).single;
    var first = true;
    engine.during = (_) async {
      if (!first) return;
      first = false;
      // Re-crop deletes the old file mid-read: the read fails.
      await (db.update(db.pages)..where((t) => t.id.equals(pg.id)))
          .write(const PagesCompanion(processedFile: Value('recropped.jpg')));
      throw Exception('无法读取图片');
    };
    await settle();
    expect(engine.calls, hasLength(2));
    expect((await db.pageById(pg.id))!.ocrText, '第2次');
  });

  test('concurrent reads of one page share the work; a late read never overwrites edits', () async {
    final doc = await newDoc(pages: 1);
    final pg = (await db.pagesOf(doc)).single;
    final a = queue.readNow(pg), b = queue.readNow(pg);
    expect(identical(a, b), isTrue);
    await a;
    expect(engine.calls, hasLength(1));

    await db.setOcrText(pg.id, '用户改过');
    await queue.readNow(pg); // e.g. an export holding an old snapshot
    expect((await db.pageById(pg.id))!.ocrText, '用户改过');

    await queue.readNow(pg, replace: true); // explicit 重新识别
    expect((await db.pageById(pg.id))!.ocrText, '第3次');
  });

  test('user edits replace the text but keep the boxes', () async {
    queue.start();
    final doc = await newDoc(pages: 1);
    await settle();
    final pg = (await db.pagesOf(doc)).single;
    await db.setOcrText(pg.id, '改过的文字');
    final after = (await db.pageById(pg.id))!;
    expect(after.ocrText, '改过的文字');
    expect(after.ocrJson, pg.ocrJson);
  });
}
