import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doc_scanner/data/app_lock.dart';
import 'package:doc_scanner/data/db.dart';
import 'package:doc_scanner/data/page_store.dart';

AppDatabase memoryDb() => AppDatabase.forTesting(NativeDatabase.memory());

/// Inserts a document with [pages] pages whose image files really exist
/// in [store]'s directory.
Future<int> addDoc(AppDatabase db, PageStore? store, String title,
    {int? folderId, int pages = 1, String? ocr, DateTime? updated}) async {
  final id = await db.into(db.documents).insert(DocumentsCompanion.insert(
        title: title,
        folderId: Value(folderId),
        updatedAt: Value(updated ?? DateTime.now()),
      ));
  for (var i = 0; i < pages; i++) {
    final base = '$title-$i'.replaceAll(' ', '_');
    if (store != null) {
      for (final n in ['$base.orig.jpg', '$base.jpg', '$base.thumb.jpg']) {
        store.file(n).writeAsStringSync('img $n');
      }
    }
    await db.into(db.pages).insert(PagesCompanion.insert(
          documentId: id,
          position: i,
          originalFile: '$base.orig.jpg',
          processedFile: '$base.jpg',
          thumbFile: '$base.thumb.jpg',
          ocrText: Value(ocr),
        ));
  }
  return id;
}

void main() {
  late AppDatabase db;
  late Directory tmp;
  late PageStore store;

  setUp(() {
    db = memoryDb();
    tmp = Directory.systemTemp.createTempSync('scanner_test_');
    store = PageStore(db, tmp);
  });

  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  group('folders', () {
    test('documents are listed per folder', () async {
      final f = await db.createFolder('发票');
      await addDoc(db, store, 'a');
      await addDoc(db, store, 'b', folderId: f);
      expect((await db.watchDocuments().first).map((d) => d.title), ['a']);
      expect((await db.watchDocuments(folderId: f).first).map((d) => d.title), ['b']);
      expect(await db.watchFolderCounts().first, {null: 1, f: 1});
    });

    test('deleting a folder trashes its whole subtree and restore lands at top level', () async {
      final parent = await db.createFolder('父');
      final child = await db.createFolder('子', parentId: parent);
      final d1 = await addDoc(db, store, 'p', folderId: parent);
      final d2 = await addDoc(db, store, 'c', folderId: child);
      final old = DateTime(2020);
      final d3 = await addDoc(db, store, 'old', folderId: child);
      await db.trashDocuments([d3], at: old);

      await db.deleteFolder(parent);

      expect(await db.watchAllFolders().first, isEmpty);
      final trash = await db.watchTrash().first;
      expect(trash.map((d) => d.id).toSet(), {d1, d2, d3});
      expect(trash.every((d) => d.folderId == null), isTrue);
      // A document that was already in the bin keeps its original date.
      expect(trash.firstWhere((d) => d.id == d3).deletedAt, old);

      await db.restoreDocuments([d1]);
      expect((await db.watchDocuments().first).map((d) => d.id), [d1]);
    });

    test('move documents between folders', () async {
      final f = await db.createFolder('F');
      final d = await addDoc(db, store, 'x');
      await db.moveDocuments([d], f);
      expect((await db.watchDocuments(folderId: f).first).single.id, d);
      await db.moveDocuments([d], null);
      expect((await db.watchDocuments().first).single.id, d);
    });
  });

  group('recycle bin', () {
    test('trashed documents leave every list but the bin', () async {
      final d = await addDoc(db, store, 'gone', ocr: 'hello');
      await db.markOpened(d);
      await db.trashDocuments([d]);
      expect(await db.watchDocuments().first, isEmpty);
      expect(await db.watchRecent().first, isEmpty);
      expect(await db.search('gone'), isEmpty);
      expect((await db.watchTrash().first).single.id, d);
    });

    test('purgeExpiredTrash removes only old entries, with their files', () async {
      final now = DateTime(2026, 11, 13);
      final oldDoc = await addDoc(db, store, 'old');
      final newDoc = await addDoc(db, store, 'new');
      await db.trashDocuments([oldDoc], at: now.subtract(const Duration(days: 31)));
      await db.trashDocuments([newDoc], at: now.subtract(const Duration(days: 29)));

      expect(await store.purgeExpiredTrash(now: now), 1);

      expect((await db.watchTrash().first).map((d) => d.id), [newDoc]);
      expect(store.file('old-0.jpg').existsSync(), isFalse);
      expect(store.file('new-0.jpg').existsSync(), isTrue);
      expect(await db.pagesOf(oldDoc), isEmpty);
    });
  });

  group('copy', () {
    test('copies pages with independent files, tags and lock', () async {
      final f = await db.createFolder('F');
      final src = await addDoc(db, store, 'src', folderId: f, pages: 2, ocr: 'text');
      final tag = await db.ensureTag('重要');
      await db.setTags([src], {tag});
      await db.setLocked([src], true);

      final copy = await store.copyDocument(src);

      final doc = (await db.documentById(copy))!;
      expect(doc.title, 'src 副本');
      expect(doc.folderId, f);
      expect(doc.locked, isTrue);
      expect(await db.tagIdsOf(copy), [tag]);
      final pages = await db.pagesOf(copy);
      expect(pages.length, 2);
      expect(pages.first.ocrText, 'text');
      for (final pg in pages) {
        expect(pg.processedFile, isNot(startsWith('src')));
        expect(store.file(pg.processedFile).existsSync(), isTrue);
      }
      // Deleting the original must not touch the copy's files.
      await store.purgeDocument(src);
      expect(store.file(pages.first.processedFile).existsSync(), isTrue);
    });
  });

  group('tags', () {
    test('filter by tag across folders; tag deletion detaches it', () async {
      final f = await db.createFolder('F');
      final a = await addDoc(db, store, 'a');
      final b = await addDoc(db, store, 'b', folderId: f);
      await addDoc(db, store, 'c');
      final t = await db.ensureTag('合同');
      expect(await db.ensureTag('合同'), t);
      await db.addTag([a, b], t);
      await db.addTag([a], t); // idempotent

      expect((await db.watchDocuments(tagId: t).first).map((d) => d.title).toSet(), {'a', 'b'});
      expect((await db.watchTagsOf(a).first).map((x) => x.name), ['合同']);

      await db.deleteTag(t);
      expect(await db.watchTagsOf(a).first, isEmpty);
    });

    test('setTags replaces the set', () async {
      final a = await addDoc(db, store, 'a');
      final t1 = await db.ensureTag('1'), t2 = await db.ensureTag('2');
      await db.setTags([a], {t1});
      await db.setTags([a], {t2});
      expect(await db.tagIdsOf(a), [t2]);
    });
  });

  group('search', () {
    test('matches title and recognized text, treats % and _ literally', () async {
      await addDoc(db, store, '租房合同');
      await addDoc(db, store, '发票', ocr: '本合同自签订之日起生效');
      await addDoc(db, store, '100% 完成');
      await addDoc(db, store, '1000 完成');

      expect((await db.search('合同')).map((d) => d.title).toSet(), {'租房合同', '发票'});
      expect((await db.search('100%')).map((d) => d.title), ['100% 完成']);
      expect(await db.search('   '), isEmpty);
      expect(await db.search('不存在'), isEmpty);
    });
  });

  test('sort orders', () async {
    await addDoc(db, store, 'b', updated: DateTime(2026, 1, 2));
    await addDoc(db, store, 'a', updated: DateTime(2026, 1, 1));
    await addDoc(db, store, 'c', updated: DateTime(2026, 1, 3));
    expect((await db.watchDocuments(sort: DocSort.title).first).map((d) => d.title), ['a', 'b', 'c']);
    expect((await db.watchDocuments(sort: DocSort.updated).first).map((d) => d.title), ['c', 'b', 'a']);
  });

  test('settings round trip', () async {
    expect(await db.getSetting('k'), isNull);
    await db.setSetting('k', 'v1');
    await db.setSetting('k', 'v2');
    expect(await db.getSetting('k'), 'v2');
    await db.setSetting('k', null);
    expect(await db.getSetting('k'), isNull);
  });

  group('app lock', () {
    test('PBKDF2-HMAC-SHA256 matches the RFC 7914 test vector', () {
      final out = AppLock.pbkdf2(utf8.encode('passwd'), utf8.encode('salt'), 1, 64);
      expect(
        out.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        '55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc'
        '49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783',
      );
    });

    test('set and verify password', () async {
      final lock = AppLock(db);
      expect(await lock.hasPassword(), isFalse);
      expect(await lock.verify('1234'), isFalse);
      await lock.setPassword('1234', iterations: 1000);
      expect(await lock.hasPassword(), isTrue);
      expect(await lock.verify('1234'), isTrue);
      expect(await lock.verify('4321'), isFalse);
      expect(() => lock.setPassword('12'), throwsArgumentError);
    });
  });

  test('upgrades a version 1 database without losing documents', () async {
    final v1 = AppDatabase.forTesting(NativeDatabase.memory(setup: (raw) {
      raw.execute('''
        CREATE TABLE folders (id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL,
          parent_id INTEGER NULL REFERENCES folders (id), created_at INTEGER NOT NULL DEFAULT (CAST(strftime('%s', CURRENT_TIMESTAMP) AS INTEGER)));
        CREATE TABLE documents (id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL,
          folder_id INTEGER NULL REFERENCES folders (id),
          created_at INTEGER NOT NULL DEFAULT (CAST(strftime('%s', CURRENT_TIMESTAMP) AS INTEGER)),
          updated_at INTEGER NOT NULL DEFAULT (CAST(strftime('%s', CURRENT_TIMESTAMP) AS INTEGER)),
          deleted_at INTEGER NULL);
        CREATE TABLE pages (id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          document_id INTEGER NOT NULL REFERENCES documents (id) ON DELETE CASCADE, position INTEGER NOT NULL,
          original_file TEXT NOT NULL, processed_file TEXT NOT NULL, thumb_file TEXT NOT NULL, quad_json TEXT NULL,
          filter TEXT NOT NULL DEFAULT 'enhance', rotation INTEGER NOT NULL DEFAULT 0, ocr_text TEXT NULL);
        INSERT INTO documents (title) VALUES ('旧文档');
        PRAGMA user_version = 1;
      ''');
    }));
    final docs = await v1.watchDocuments().first;
    expect(docs.single.title, '旧文档');
    expect(docs.single.locked, isFalse);
    expect(docs.single.lastOpenedAt, isNull);
    final t = await v1.ensureTag('新');
    await v1.addTag([docs.single.id], t);
    await v1.setSetting('x', 'y');
    expect(await v1.getSetting('x'), 'y');
    await v1.close();
  });
}
