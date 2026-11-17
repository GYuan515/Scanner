import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:doc_scanner/data/db.dart';
import 'package:doc_scanner/data/exporter.dart';
import 'package:doc_scanner/data/page_store.dart';
import 'package:doc_scanner/markup/compositor.dart';
import 'package:doc_scanner/markup/markup.dart';
import 'package:doc_scanner/markup/watermark.dart';
import 'package:doc_scanner/scan/image_ops.dart';

void main() {
  late AppDatabase db;
  late Directory tmp;
  late PageStore store;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    tmp = Directory.systemTemp.createTempSync('scanner_compose_');
    store = PageStore(db, tmp);
  });

  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  Future<ScanPage> whitePage() async {
    final m = cv.Mat.fromScalar(400, 300, cv.MatType.CV_8UC3, cv.Scalar(255, 255, 255));
    final jpg = ImageOps.encodeJpeg(m, quality: 95);
    m.dispose();
    final doc = await store.createDocument('文档', [DraftPage(original: jpg, width: 300, height: 400, filter: ScanFilter.original)]);
    return (await db.pagesOf(doc)).single;
  }

  (int, int, int) bgrAt(Uint8List jpg, int x, int y) {
    final m = cv.imdecode(jpg, cv.IMREAD_COLOR);
    final v = m.atPixel(y, x);
    m.dispose();
    return (v[0].toInt(), v[1].toInt(), v[2].toInt());
  }

  testWidgets('markup and watermark are burned into the exported image', (tester) async {
    await tester.runAsync(() async {
      var pg = await whitePage();
      final plain = await PageCompositor(store).compose(pg);
      expect(plain, await store.file(pg.processedFile).readAsBytes(), reason: 'nothing to draw: file as is');

      await store.setMarkup(pg, const PageMarkup([
        MarkupItem(kind: MarkupKind.highlight, rect: Rect.fromLTWH(20, 20, 100, 30), color: 0x99FFEB3B),
        MarkupItem(kind: MarkupKind.ink, points: [Offset(20, 200), Offset(280, 200)], width: 10, color: 0xFF1565C0),
      ]));
      pg = (await db.pageById(pg.id))!;
      final out = await PageCompositor(store).compose(pg);
      final (b1, g1, r1) = bgrAt(out, 60, 35); // highlight: yellow tint, blue channel drops
      expect(b1, lessThan(200));
      expect(r1, greaterThan(220));
      final (b2, _, r2) = bgrAt(out, 150, 200); // blue ink
      expect(b2, greaterThan(150));
      expect(r2, lessThan(80));
      final (b3, g3, r3) = bgrAt(out, 150, 350); // untouched
      expect([b3, g3, r3].every((v) => v > 240), isTrue);
      expect(g1, greaterThan(200));

      // A centred, opaque-ish text watermark darkens the middle of the page.
      final wm = await PageCompositor(store)
          .compose(pg, watermark: const Watermark(text: '机密机密', opacity: 0.9, size: 0.12, tiled: false, color: 0xFF000000));
      final m = cv.imdecode(wm, cv.IMREAD_GRAYSCALE);
      final centre = m.region(cv.Rect(100, 170, 100, 60));
      expect(cv.mean(centre).val1, lessThan(235));
      centre.dispose();
      m.dispose();
    });
  });

  testWidgets('notes become PDF text annotations', (tester) async {
    await tester.runAsync(() async {
      var pg = await whitePage();
      await store.setMarkup(pg, const PageMarkup([
        MarkupItem(kind: MarkupKind.note, rect: Rect.fromLTWH(50, 60, 24, 24), text: '这里要改'),
      ]));
      pg = (await db.pageById(pg.id))!;
      final bytes = await Exporter(store).buildPdf([pg], options: const PdfOptions(searchable: false));
      final s = String.fromCharCodes(bytes);
      expect(RegExp(r'/Subtype\s*/Text').hasMatch(s), isTrue);
      expect(RegExp(r'/Annots').hasMatch(s), isTrue);
    });
  });
}
