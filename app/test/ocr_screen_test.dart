import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doc_scanner/app_state.dart';
import 'package:doc_scanner/data/db.dart';
import 'package:doc_scanner/data/page_store.dart';
import 'package:doc_scanner/ocr/ocr_queue.dart';
import 'package:doc_scanner/ocr/ocr_result.dart';
import 'package:doc_scanner/scan/image_ops.dart';
import 'package:doc_scanner/ui/ocr_screen.dart';

class FakeEngine implements OcrEngine {
  int calls = 0;
  @override
  Future<OcrResult> recognizeFile(String path, {Rect? region}) async {
    calls++;
    return OcrResult(width: 1240, height: 1754, rows: [
      [const OcrLine([Offset(100, 120), Offset(600, 120), Offset(600, 190), Offset(100, 190)], '增值税专用发票', 0.98)],
      [const OcrLine([Offset(100, 250), Offset(800, 250), Offset(800, 290), Offset(100, 290)], '购买方名称', 0.99)],
    ]);
  }
}

void main() {
  late AppDatabase db;
  late Directory tmp;
  late PageStore store;
  late FakeEngine engine;
  late int pageId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    tmp = Directory.systemTemp.createTempSync('scanner_ocr_ui_');
    store = PageStore(db, tmp);
    engine = FakeEngine();
  });

  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.runAsync(() async {
      final jpeg = File('test/fixtures/ocr_page.jpg').readAsBytesSync();
      final doc = await store.createDocument('发票', [
        DraftPage(original: Uint8List.fromList(jpeg), width: 1240, height: 1754, filter: ScanFilter.original),
      ]);
      pageId = (await db.pagesOf(doc)).single.id;
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [
        dbProvider.overrideWithValue(db),
        storeProvider.overrideWithValue(store),
        ocrEngineProvider.overrideWith((ref) async => engine),
      ],
      child: MaterialApp(home: OcrScreen(pageId: pageId)),
    ));
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
  }

  Future<void> disposeTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(Duration.zero);
    }
  }

  testWidgets('reads a page without text once and shows the result', (tester) async {
    await pump(tester);
    expect(engine.calls, 1);
    expect(find.text('增值税专用发票\n购买方名称'), findsOneWidget);
    final pg = await tester.runAsync(() => db.pageById(pageId));
    expect(pg!.ocrText, '增值税专用发票\n购买方名称');
    await disposeTree(tester);
  });

  testWidgets('edits are saved, also when leaving before the debounce', (tester) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField), '改过的文字');
    await tester.pump();
    await disposeTree(tester); // leave immediately
    final pg = await tester.runAsync(() => db.pageById(pageId));
    expect(pg!.ocrText, '改过的文字');
    expect(engine.calls, 1);
  });
}
