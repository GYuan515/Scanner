import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:doc_scanner/data/db.dart';
import 'package:doc_scanner/data/page_store.dart';
import 'package:doc_scanner/markup/markup.dart';
import 'package:doc_scanner/markup/watermark.dart';
import 'package:doc_scanner/scan/image_ops.dart';

void main() {
  late AppDatabase db;
  late Directory tmp;
  late PageStore store;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    tmp = Directory.systemTemp.createTempSync('scanner_markup_');
    store = PageStore(db, tmp);
  });

  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  /// A white 800x600 photo with a black dot at (600, 150).
  Uint8List photo() {
    final m = cv.Mat.fromScalar(600, 800, cv.MatType.CV_8UC3, cv.Scalar(255, 255, 255));
    cv.circle(m, cv.Point(600, 150), 20, cv.Scalar(0, 0, 0), thickness: -1);
    final jpg = ImageOps.encodeJpeg(m, quality: 95);
    m.dispose();
    return jpg;
  }

  int grayAt(String path, int x, int y) {
    final m = cv.imread(path, flags: cv.IMREAD_GRAYSCALE);
    final v = m.at<int>(y, x);
    m.dispose();
    return v;
  }

  Future<ScanPage> newPage() async {
    final doc = await store.createDocument('文档', [
      DraftPage(original: photo(), width: 800, height: 600, filter: ScanFilter.original),
    ]);
    return (await db.pagesOf(doc)).single;
  }

  test('rotating a page carries its markup along', () async {
    var pg = await newPage();
    await store.setMarkup(pg, const PageMarkup([
      MarkupItem(kind: MarkupKind.highlight, rect: Rect.fromLTWH(560, 110, 80, 80)),
    ]));
    pg = (await db.pageById(pg.id))!;
    await store.updatePage(pg, rotation: 1);
    pg = (await db.pageById(pg.id))!;
    final r = PageMarkup.parse(pg.markupJson).items.single.rect;
    // The dot at (600,150) is now at (600-1-150, 600) = (449, 600).
    expect(r.center.dx, closeTo(449, 1.5));
    expect(r.center.dy, closeTo(600, 1.5));
    expect(grayAt(store.file(pg.processedFile).path, 449, 600), lessThan(60));
    // A filter change leaves markup alone.
    final before = pg.markupJson;
    await store.updatePage(pg, filter: ScanFilter.grayscale);
    expect((await db.pageById(pg.id))!.markupJson, before);
  });

  test('redaction removes the pixels from the photo and the page, and clears OCR', () async {
    var pg = await newPage();
    await store.updatePage(pg, rotation: 2); // redaction must undo the turn
    pg = (await db.pageById(pg.id))!;
    await db.saveOcr(pg.id, text: '秘密', json: '{"w":1,"h":1,"rows":[]}', processedFile: pg.processedFile);
    pg = (await db.pageById(pg.id))!;
    // After a half turn the dot sits at (799-600, 599-150) = (199, 449).
    expect(grayAt(store.file(pg.processedFile).path, 199, 449), lessThan(60));
    // White pixels near the dot stay white before redaction.
    expect(grayAt(store.file(pg.originalFile).path, 650, 150), greaterThan(200));

    await store.redact(pg, [const Rect.fromLTWH(140, 400, 120, 100)]);
    final after = (await db.pageById(pg.id))!;
    expect(after.ocrText, isNull);
    expect(after.ocrJson, isNull);
    expect(after.originalFile, isNot(pg.originalFile));
    expect(File(store.file(pg.originalFile).path).existsSync(), isFalse, reason: 'old photo deleted');
    // Covered area is black in the stored photo itself, around the dot too.
    expect(grayAt(store.file(after.originalFile).path, 650, 150), lessThan(30));
    expect(grayAt(store.file(after.processedFile).path, 199 - 40, 449), lessThan(30));
    // Outside stays white.
    expect(grayAt(store.file(after.originalFile).path, 100, 500), greaterThan(200));
  });

  test('signature files: removed with the item, copied with the document, purged with it', () async {
    var pg = await newPage();
    final sig = await store.addMarkupImage(Uint8List.fromList([137, 80, 78, 71]));
    await store.setMarkup(pg, PageMarkup([
      MarkupItem(kind: MarkupKind.image, rect: const Rect.fromLTWH(10, 10, 100, 40), image: sig),
    ]));
    pg = (await db.pageById(pg.id))!;
    final doc = (await db.documentById(pg.documentId))!;
    final wm = await store.addWatermarkImage(Uint8List.fromList([1, 2, 3]));
    await store.setWatermark(doc, Watermark(image: wm));

    final copyId = await store.copyDocument(pg.documentId);
    final copyPage = (await db.pagesOf(copyId)).single;
    final copySig = PageMarkup.parse(copyPage.markupJson).items.single.image!;
    final copyWm = Watermark.parse((await db.documentById(copyId))!.watermarkJson)!.image!;
    expect(copySig, isNot(sig));
    expect(copyWm, isNot(wm));
    expect(store.file(copySig).existsSync(), isTrue);
    expect(store.file(copyWm).existsSync(), isTrue);

    // Removing the item deletes the page's copy only.
    await store.setMarkup(pg, PageMarkup.empty);
    expect(store.file(sig).existsSync(), isFalse);
    expect(store.file(copySig).existsSync(), isTrue);

    await store.purgeDocument(copyId);
    expect(store.file(copySig).existsSync(), isFalse);
    expect(store.file(copyWm).existsSync(), isFalse);
    expect(store.file(wm).existsSync(), isTrue);
  });

  test('retaking a page drops the old photo markup and its files', () async {
    var pg = await newPage();
    final sig = await store.addMarkupImage(Uint8List.fromList([137, 80, 78, 71]));
    await store.setMarkup(pg, PageMarkup([
      MarkupItem(kind: MarkupKind.image, rect: const Rect.fromLTWH(10, 10, 100, 40), image: sig),
    ]));
    pg = (await db.pageById(pg.id))!;
    await store.replacePage(pg, DraftPage(original: photo(), width: 800, height: 600, filter: ScanFilter.original));
    expect((await db.pageById(pg.id))!.markupJson, isNull);
    expect(store.file(sig).existsSync(), isFalse);
  });

  test('a copy survives a lost signature file', () async {
    var pg = await newPage();
    await store.setMarkup(pg, const PageMarkup([
      MarkupItem(kind: MarkupKind.image, rect: Rect.fromLTWH(10, 10, 100, 40), image: 'gone.mark.png'),
      MarkupItem(kind: MarkupKind.ink, points: [Offset(1, 1), Offset(5, 5)]),
    ]));
    final copyId = await store.copyDocument(pg.documentId);
    final copied = PageMarkup.parse((await db.pagesOf(copyId)).single.markupJson);
    expect(copied.items.single.kind, MarkupKind.ink);
  });

  test('geometryOf matches the processed image size', () async {
    var pg = await newPage();
    await store.updatePage(pg, rotation: 1);
    pg = (await db.pageById(pg.id))!;
    final g = await store.geometryOf(pg);
    final m = cv.imread(store.file(pg.processedFile).path);
    expect((g.processedSize.width, g.processedSize.height), (m.cols.toDouble(), m.rows.toDouble()));
    m.dispose();
    expect(g.fromOriginal(const Offset(600, 150)).dx, closeTo(449, 0.01));
  });
}
