import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doc_scanner/app_state.dart';
import 'package:doc_scanner/data/db.dart';
import 'package:doc_scanner/data/page_store.dart';
import 'package:doc_scanner/ui/home_screen.dart';

void main() {
  late AppDatabase db;
  late Directory tmp;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    tmp = Directory.systemTemp.createTempSync('scanner_widget_');
  });

  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  Future<void> pumpLibrary(WidgetTester tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        dbProvider.overrideWithValue(db),
        storeProvider.overrideWithValue(PageStore(db, tmp)),
      ],
      child: const MaterialApp(home: LibraryScreen()),
    ));
    // Let drift's streams deliver their first results.
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
  }

  /// Tears the tree down and lets drift's stream cleanup timers run, so
  /// the test does not fail on "a Timer is still pending".
  Future<void> disposeTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 3; i++) {
      await tester.pump(Duration.zero);
    }
  }

  testWidgets('shows folders, documents, selection mode and tag filter', (tester) async {
    late int tagged;
    await tester.runAsync(() async {
      final f = await db.createFolder('发票');
      await db.into(db.documents).insert(DocumentsCompanion.insert(title: '放在文件夹里', folderId: Value(f)));
      tagged = await db.into(db.documents).insert(DocumentsCompanion.insert(title: '合同扫描'));
      await db.into(db.documents).insert(DocumentsCompanion.insert(title: '随手拍'));
      await db.addTag([tagged], await db.ensureTag('重要'));
    });

    await pumpLibrary(tester);

    expect(find.text('我的文档'), findsOneWidget);
    expect(find.text('发票'), findsOneWidget);
    expect(find.text('1 个文档'), findsOneWidget);
    expect(find.text('合同扫描'), findsOneWidget);
    expect(find.text('随手拍'), findsOneWidget);
    expect(find.text('放在文件夹里'), findsNothing);

    // Long press enters selection mode.
    await tester.longPress(find.text('随手拍'));
    await tester.pump();
    expect(find.text('已选 1 个'), findsOneWidget);
    await tester.tap(find.text('合同扫描'));
    await tester.pump();
    expect(find.text('已选 2 个'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(find.text('我的文档'), findsOneWidget);

    // Tag filter hides folders and untagged documents.
    await tester.tap(find.text('#重要'));
    await settle(tester);
    expect(find.text('合同扫描'), findsOneWidget);
    expect(find.text('随手拍'), findsNothing);
    expect(find.text('发票'), findsNothing);

    await disposeTree(tester);
  });

  testWidgets('view mode switch shows a grid', (tester) async {
    await tester.runAsync(() => db.into(db.documents).insert(DocumentsCompanion.insert(title: 'A')));
    await pumpLibrary(tester);
    expect(find.byType(ListTile), findsWidgets);

    await tester.tap(find.byTooltip('显示方式'));
    // Not pumpAndSettle: the database streams keep scheduling frames, so
    // it would never report a settled tree.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // menu animation
    // Tap the menu item, not its label: the item absorbs the hit test.
    await tester.tap(find.widgetWithText(CheckedPopupMenuItem<Object>, '网格'));
    await settle(tester);
    expect(find.byType(Card), findsOneWidget);
    expect(await tester.runAsync(() => db.getSetting('ui.view')), 'grid');

    await disposeTree(tester);
  });
}
