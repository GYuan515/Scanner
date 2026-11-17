import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:doc_scanner/app_state.dart';
import 'package:doc_scanner/data/db.dart';
import 'package:doc_scanner/data/page_store.dart';
import 'package:doc_scanner/markup/markup.dart';
import 'package:doc_scanner/markup/markup_painter.dart';
import 'package:doc_scanner/ocr/ocr_result.dart';
import 'package:doc_scanner/scan/image_ops.dart';
import 'package:doc_scanner/ui/annotate_screen.dart';
import 'package:doc_scanner/ui/quad_overlay.dart';

void main() {
  late AppDatabase db;
  late Directory tmp;
  late PageStore store;
  late int pageId;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    tmp = Directory.systemTemp.createTempSync('scanner_annotate_');
    store = PageStore(db, tmp);
  });

  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  Future<void> settle(WidgetTester tester, [int n = 8]) async {
    for (var i = 0; i < n; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
  }

  /// Current image -> screen mapping. Recomputed after tool changes: the
  /// toolbar height (and so the image area) depends on the tool.
  ImageMapping mapping(WidgetTester tester) {
    final overlay = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is MarkupOverlayPainter);
    final rect = tester.getRect(overlay);
    return _Shifted(ImageMapping(const Size(800, 1000), rect.size), rect.topLeft);
  }

  Future<ImageMapping> open(WidgetTester tester) async {
    await tester.runAsync(() async {
      final m = cv.Mat.fromScalar(1000, 800, cv.MatType.CV_8UC3, cv.Scalar(255, 255, 255));
      final jpg = ImageOps.encodeJpeg(m);
      m.dispose();
      final doc = await store.createDocument('文档', [DraftPage(original: Uint8List.fromList(jpg), width: 800, height: 1000, filter: ScanFilter.original)]);
      final pg = (await db.pagesOf(doc)).single;
      pageId = pg.id;
      // One recognized line at y 300..340, x 100..700.
      final ocr = OcrResult(width: 800, height: 1000, rows: [
        [const OcrLine([Offset(100, 300), Offset(700, 300), Offset(700, 340), Offset(100, 340)], '第一行文字', 1)],
      ]);
      await db.saveOcr(pg.id, text: ocr.text, json: ocr.toJsonString(), processedFile: pg.processedFile);
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [dbProvider.overrideWithValue(db), storeProvider.overrideWithValue(store)],
      child: MaterialApp(home: AnnotateScreen(pageId: pageId)),
    ));
    await settle(tester);
    return mapping(tester);
  }

  Future<PageMarkup> saved(WidgetTester tester) async =>
      PageMarkup.parse((await tester.runAsync(() => db.pageById(pageId)))!.markupJson);

  testWidgets('pen stroke is saved; highlight snaps to the text line; undo and eraser', (tester) async {
    var m = await open(tester);

    // Pen is the default tool.
    await tester.dragFrom(m.toView(const Offset(100, 600)), m.toView(const Offset(500, 700)) - m.toView(const Offset(100, 600)));
    await settle(tester);
    var mk = await saved(tester);
    expect(mk.items.single.kind, MarkupKind.ink);
    expect(mk.items.single.points.length, greaterThan(2));

    // Highlight: a sloppy drag over the line, taller than the line.
    await tester.tap(find.text('高亮'));
    await tester.pump();
    m = mapping(tester);
    await tester.dragFrom(m.toView(const Offset(150, 280)), m.toView(const Offset(450, 360)) - m.toView(const Offset(150, 280)));
    await settle(tester);
    mk = await saved(tester);
    final hl = mk.items.last;
    expect(hl.kind, MarkupKind.highlight);
    expect(hl.rect.top, closeTo(300, 0.01));
    expect(hl.rect.bottom, closeTo(340, 0.01));
    expect(hl.rect.left, closeTo(150, 3));
    expect(hl.rect.right, closeTo(450, 3));

    // Undo removes the highlight again.
    await tester.tap(find.byTooltip('撤销'));
    await settle(tester);
    expect((await saved(tester)).items.length, 1);

    // Eraser removes the stroke.
    await tester.tap(find.text('橡皮'));
    await tester.pump();
    m = mapping(tester);
    final onStroke = mk.items.first.points[mk.items.first.points.length ~/ 2];
    await tester.tapAt(m.toView(onStroke));
    await settle(tester);
    expect((await saved(tester)).isEmpty, isTrue);

    await tester.pumpWidget(const SizedBox());
    await settle(tester, 3);
  });
}

/// ImageMapping whose view coordinates are global (screen) coordinates.
class _Shifted extends ImageMapping {
  _Shifted(ImageMapping m, this.origin) : super(m.image, m.view);
  final Offset origin;

  @override
  Offset toView(Offset p) => super.toView(p) + origin;

  @override
  Offset toImage(Offset v) => super.toImage(v - origin);
}
