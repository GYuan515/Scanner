import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:doc_scanner/app_state.dart';
import 'package:doc_scanner/data/db.dart';
import 'package:doc_scanner/data/page_store.dart';
import 'package:doc_scanner/scan/image_ops.dart';
import 'package:doc_scanner/ui/page_screen.dart';

/// Screens rendered at the width of the user's phone (1260 px at 3.5x =
/// 360 dp). A RenderFlex overflow is reported as an error and fails the
/// test, instead of showing up as a striped bar on the device.
void main() {
  late AppDatabase db;
  late Directory tmp;
  late PageStore store;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    tmp = Directory.systemTemp.createTempSync('scanner_narrow_');
    store = PageStore(db, tmp);
  });

  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  testWidgets('page screen toolbar fits a 360 dp wide phone', (tester) async {
    tester.view.physicalSize = const Size(1260, 2800);
    tester.view.devicePixelRatio = 3.5;
    addTearDown(tester.view.reset);

    late int docId;
    await tester.runAsync(() async {
      final m = cv.Mat.fromScalar(400, 300, cv.MatType.CV_8UC3, cv.Scalar(255, 255, 255));
      final jpg = ImageOps.encodeJpeg(m);
      m.dispose();
      docId = await store.createDocument('文档', [DraftPage(original: jpg, width: 300, height: 400, filter: ScanFilter.original)]);
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [dbProvider.overrideWithValue(db), storeProvider.overrideWithValue(store)],
      child: MaterialApp(home: PageScreen(docId: docId, initialIndex: 0)),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
    for (final label in ['裁剪', '滤镜', '旋转', '重拍', '文字', '标注']) {
      final r = tester.getRect(find.text(label));
      expect(r.right, lessThanOrEqualTo(360), reason: label);
    }
    expect(tester.takeException(), isNull);

    // Let drift's 0-duration stream cleanup timers fire inside fake time.
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 3; i++) {
      await tester.pump(Duration.zero);
    }
  });
}
