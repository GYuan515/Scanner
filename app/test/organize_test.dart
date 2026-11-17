import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:doc_scanner/data/db.dart';
import 'package:doc_scanner/data/page_store.dart';
import 'package:doc_scanner/markup/markup.dart';
import 'package:doc_scanner/scan/image_ops.dart';

void main() {
  late AppDatabase db;
  late Directory tmp;
  late PageStore store;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    tmp = Directory.systemTemp.createTempSync('scanner_organize_');
    store = PageStore(db, tmp);
  });

  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  Uint8List jpg(int shade) {
    final m = cv.Mat.fromScalar(120, 90, cv.MatType.CV_8UC3, cv.Scalar.all(shade.toDouble()));
    final b = ImageOps.encodeJpeg(m);
    m.dispose();
    return b;
  }

  Future<int> doc(String title, int pages) => store.createDocument(title, [
        for (var i = 0; i < pages; i++) DraftPage(original: jpg(40 * i + 20), width: 90, height: 120, filter: ScanFilter.original),
      ]);

  Future<List<String>> texts(int docId) async => [for (final p in await db.pagesOf(docId)) p.ocrText ?? ''];

  Future<void> label(int docId, String prefix) async {
    final pages = await db.pagesOf(docId);
    for (var i = 0; i < pages.length; i++) {
      await db.setOcrText(pages[i].id, '$prefix${i + 1}');
    }
  }

  test('merge copies all pages in document order and keeps the originals', () async {
    final a = await doc('甲', 2), b = await doc('乙', 1);
    await label(a, 'a');
    await label(b, 'b');
    await db.addTag([b], await db.ensureTag('发票'));
    final merged = await store.mergeDocuments([b, a], title: '合并');
    expect(await texts(merged), ['b1', 'a1', 'a2']);
    expect((await db.pagesOf(merged)).map((p) => p.position), [0, 1, 2]);
    expect((await db.documentById(merged))!.title, '合并');
    expect(await db.tagIdsOf(merged), await db.tagIdsOf(b));
    expect(await texts(a), ['a1', 'a2']);
    // Own files: deleting the source does not break the merged document.
    await store.purgeDocument(a);
    for (final p in await db.pagesOf(merged)) {
      expect(store.file(p.processedFile).existsSync(), isTrue);
    }
  });

  test('extract copies; split moves and renumbers the source', () async {
    final d = await doc('原文档', 4);
    await label(d, 'p');
    final pages = await db.pagesOf(d);
    final sig = await store.addMarkupImage(Uint8List.fromList([137, 80, 78, 71]));
    await store.setMarkup(pages[2], PageMarkup([
      MarkupItem(kind: MarkupKind.image, rect: const Rect.fromLTWH(1, 1, 10, 10), image: sig),
    ]));

    final copy = await store.extractPages(d, {pages[2].id, pages[0].id}, title: '摘出');
    expect(await texts(copy), ['p1', 'p3'], reason: 'page order, not selection order');
    final copiedSig = PageMarkup.parse((await db.pagesOf(copy))[1].markupJson).items.single.image;
    expect(copiedSig, isNot(sig));
    expect(await texts(d), ['p1', 'p2', 'p3', 'p4']);

    final split = await store.extractPages(d, {pages[1].id, pages[3].id}, title: '拆出', move: true);
    expect(await texts(split), ['p2', 'p4']);
    expect(await texts(d), ['p1', 'p3']);
    expect((await db.pagesOf(d)).map((p) => p.position), [0, 1]);
    expect(store.file(pages[1].processedFile).existsSync(), isFalse);

    await expectLater(store.extractPages(d, {for (final p in await db.pagesOf(d)) p.id}, title: 'x', move: true), throwsStateError);
  });
}
