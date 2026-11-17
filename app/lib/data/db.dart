import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'db.g.dart';

class Folders extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().withLength(min: 1, max: 120)();
  IntColumn get parentId => integer().nullable().references(Folders, #id)();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

class Documents extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get title => text().withLength(min: 1, max: 200)();
  IntColumn get folderId => integer().nullable().references(Folders, #id)();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  /// Set when moved to the recycle bin; null for live documents.
  DateTimeColumn get deletedAt => dateTime().nullable()();

  /// Locked documents need fingerprint or the app password to open (v2).
  BoolColumn get locked => boolean().withDefault(const Constant(false))();

  /// For the "recent" list (v2).
  DateTimeColumn get lastOpenedAt => dateTime().nullable()();

  /// `Watermark` JSON, drawn on every page when reading and exporting (v4).
  TextColumn get watermarkJson => text().nullable()();
}

@DataClassName('ScanPage')
class Pages extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get documentId => integer().references(Documents, #id, onDelete: KeyAction.cascade)();
  IntColumn get position => integer()();

  /// File names relative to the app's pages directory.
  TextColumn get originalFile => text()();
  TextColumn get processedFile => text()();
  TextColumn get thumbFile => text()();

  /// JSON-encoded [Quad] in original-image pixels; null = full image.
  TextColumn get quadJson => text().nullable()();
  TextColumn get filter => text().withDefault(const Constant('enhance'))();
  IntColumn get rotation => integer().withDefault(const Constant(0))();

  /// Recognized text, filled in by OCR. The user may edit it, so it can
  /// differ from the text in [ocrJson].
  TextColumn get ocrText => text().nullable()();

  /// [OcrResult] JSON (boxes in processed-image pixels); null = not read
  /// yet. Cleared when the page geometry changes so it gets read again.
  TextColumn get ocrJson => text().nullable()();

  /// `PageMarkup` JSON: annotations, signatures, notes, in processed-image
  /// pixels (v4). Remapped when the crop or rotation changes.
  TextColumn get markupJson => text().nullable()();
}

class Tags extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().withLength(min: 1, max: 40).unique()();
}

class DocumentTags extends Table {
  IntColumn get documentId => integer().references(Documents, #id, onDelete: KeyAction.cascade)();
  IntColumn get tagId => integer().references(Tags, #id, onDelete: KeyAction.cascade)();

  @override
  Set<Column> get primaryKey => {documentId, tagId};
}

/// Small key/value store for preferences and the lock password hash.
class Settings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

enum DocSort {
  updated('最近修改'),
  created('创建时间'),
  title('名称');

  const DocSort(this.label);
  final String label;
}

@DriftDatabase(tables: [Folders, Documents, Pages, Tags, DocumentTags, Settings])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(driftDatabase(name: 'scanner'));
  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 4;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.addColumn(documents, documents.locked);
            await m.addColumn(documents, documents.lastOpenedAt);
            await m.createTable(tags);
            await m.createTable(documentTags);
            await m.createTable(settings);
          }
          if (from < 3) {
            await m.addColumn(pages, pages.ocrJson);
          }
          if (from < 4) {
            await m.addColumn(pages, pages.markupJson);
            await m.addColumn(documents, documents.watermarkJson);
          }
        },
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );

  // ---------------------------------------------------------------- documents

  OrderingTerm Function(Documents) _order(DocSort sort) => switch (sort) {
        DocSort.updated => (d) => OrderingTerm.desc(d.updatedAt),
        DocSort.created => (d) => OrderingTerm.desc(d.createdAt),
        DocSort.title => (d) => OrderingTerm.asc(d.title),
      };

  /// Live documents in [folderId] (null = top level). With [tagId], all
  /// live documents carrying that tag, regardless of folder.
  Stream<List<Document>> watchDocuments({int? folderId, int? tagId, DocSort sort = DocSort.updated}) {
    final q = select(documents)..where((d) => d.deletedAt.isNull());
    if (tagId != null) {
      q.where((d) => d.id.isInQuery(selectOnly(documentTags)
        ..addColumns([documentTags.documentId])
        ..where(documentTags.tagId.equals(tagId))));
    } else {
      q.where((d) => folderId == null ? d.folderId.isNull() : d.folderId.equals(folderId));
    }
    q.orderBy([_order(sort), (d) => OrderingTerm.desc(d.id)]);
    return q.watch();
  }

  Stream<List<Document>> watchRecent({int limit = 50}) {
    final q = select(documents)
      ..where((d) => d.deletedAt.isNull() & d.lastOpenedAt.isNotNull())
      ..orderBy([(d) => OrderingTerm.desc(d.lastOpenedAt)])
      ..limit(limit);
    return q.watch();
  }

  Stream<List<Document>> watchTrash() {
    final q = select(documents)
      ..where((d) => d.deletedAt.isNotNull())
      ..orderBy([(d) => OrderingTerm.desc(d.deletedAt)]);
    return q.watch();
  }

  /// Live documents whose title or recognized text contains [query]
  /// (case-insensitive for Latin letters). LIKE rather than FTS5: the
  /// default FTS tokenizer treats a run of Chinese characters as one
  /// token, so it cannot find a word inside a sentence.
  Future<List<Document>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final pattern = '%${escapeLike(q)}%';
    final rows = await customSelect(
      r'''
      SELECT * FROM documents d
      WHERE d.deleted_at IS NULL AND (
        d.title LIKE ?1 ESCAPE '\'
        OR EXISTS (SELECT 1 FROM pages p WHERE p.document_id = d.id AND p.ocr_text LIKE ?1 ESCAPE '\')
      )
      ORDER BY d.updated_at DESC
      LIMIT 200
      ''',
      variables: [Variable.withString(pattern)],
      readsFrom: {documents, pages},
    ).get();
    return [for (final r in rows) await documents.mapFromRow(r)];
  }

  static String escapeLike(String s) => s.replaceAllMapped(RegExp(r'[\\%_]'), (m) => '\\${m[0]}');

  Stream<Document?> watchDocument(int id) => (select(documents)..where((d) => d.id.equals(id))).watchSingleOrNull();

  Future<Document?> documentById(int id) => (select(documents)..where((d) => d.id.equals(id))).getSingleOrNull();

  Future<void> touch(int documentId) =>
      (update(documents)..where((d) => d.id.equals(documentId))).write(DocumentsCompanion(updatedAt: Value(DateTime.now())));

  Future<void> markOpened(int documentId) =>
      (update(documents)..where((d) => d.id.equals(documentId))).write(DocumentsCompanion(lastOpenedAt: Value(DateTime.now())));

  Future<void> setWatermark(int id, String? json) =>
      (update(documents)..where((d) => d.id.equals(id))).write(DocumentsCompanion(watermarkJson: Value(json)));

  Future<void> renameDocument(int id, String title) =>
      (update(documents)..where((d) => d.id.equals(id))).write(DocumentsCompanion(title: Value(title)));

  Future<void> moveDocuments(Iterable<int> ids, int? folderId) =>
      (update(documents)..where((d) => d.id.isIn(ids))).write(DocumentsCompanion(folderId: Value(folderId)));

  Future<void> setLocked(Iterable<int> ids, bool locked) =>
      (update(documents)..where((d) => d.id.isIn(ids))).write(DocumentsCompanion(locked: Value(locked)));

  /// Moves documents to the recycle bin.
  Future<void> trashDocuments(Iterable<int> ids, {DateTime? at}) =>
      (update(documents)..where((d) => d.id.isIn(ids))).write(DocumentsCompanion(deletedAt: Value(at ?? DateTime.now())));

  /// Restores from the recycle bin. A document whose folder was deleted
  /// already had its folder cleared, so it comes back at the top level.
  Future<void> restoreDocuments(Iterable<int> ids) =>
      (update(documents)..where((d) => d.id.isIn(ids))).write(const DocumentsCompanion(deletedAt: Value(null)));

  Future<List<int>> trashedBefore(DateTime cutoff) async {
    final q = selectOnly(documents)
      ..addColumns([documents.id])
      ..where(documents.deletedAt.isSmallerThanValue(cutoff));
    return [for (final r in await q.get()) r.read(documents.id)!];
  }

  // -------------------------------------------------------------------- pages

  Stream<List<ScanPage>> watchPages(int documentId) {
    final q = select(pages)
      ..where((p) => p.documentId.equals(documentId))
      ..orderBy([(p) => OrderingTerm.asc(p.position)]);
    return q.watch();
  }

  Future<List<ScanPage>> pagesOf(int documentId) {
    final q = select(pages)
      ..where((p) => p.documentId.equals(documentId))
      ..orderBy([(p) => OrderingTerm.asc(p.position)]);
    return q.get();
  }

  Stream<ScanPage?> watchPage(int id) => (select(pages)..where((p) => p.id.equals(id))).watchSingleOrNull();

  Future<ScanPage?> pageById(int id) => (select(pages)..where((p) => p.id.equals(id))).getSingleOrNull();

  // ---------------------------------------------------------------------- ocr

  /// Pages of live documents that have not been read yet, newest first,
  /// skipping [skip] (pages that failed this session). With [only], just
  /// those pages.
  Future<List<ScanPage>> pagesNeedingOcr({Set<int> skip = const {}, Set<int>? only, int limit = 20}) async {
    if (only != null && only.isEmpty) return const [];
    final q = select(pages).join([innerJoin(documents, documents.id.equalsExp(pages.documentId))])
      ..where(pages.ocrJson.isNull() & documents.deletedAt.isNull())
      ..orderBy([OrderingTerm.desc(pages.id)])
      ..limit(limit);
    if (skip.isNotEmpty) q.where(pages.id.isNotIn(skip));
    if (only != null) q.where(pages.id.isIn(only));
    return q.map((r) => r.readTable(pages)).get();
  }

  /// Number of pages still waiting for OCR, live.
  Stream<int> watchOcrPendingCount() {
    final n = pages.id.count();
    final q = selectOnly(pages).join([innerJoin(documents, documents.id.equalsExp(pages.documentId))])
      ..addColumns([n])
      ..where(pages.ocrJson.isNull() & documents.deletedAt.isNull());
    return q.map((r) => r.read(n) ?? 0).watchSingle();
  }

  /// Stores an OCR result. The write only happens while the page still
  /// shows [processedFile]: a page re-cropped or re-filtered while it was
  /// being read keeps waiting and is read again from the new image. With
  /// [onlyIfEmpty], a page that already has a result is left alone, so a
  /// late duplicate read cannot overwrite the user's edits.
  Future<bool> saveOcr(
    int pageId, {
    required String text,
    required String json,
    required String processedFile,
    bool onlyIfEmpty = false,
  }) async {
    final q = update(pages)..where((p) => p.id.equals(pageId) & p.processedFile.equals(processedFile));
    if (onlyIfEmpty) q.where((p) => p.ocrJson.isNull());
    final n = await q.write(PagesCompanion(ocrText: Value(text), ocrJson: Value(json)));
    return n > 0;
  }

  Future<void> setMarkup(int pageId, String? json) =>
      (update(pages)..where((p) => p.id.equals(pageId))).write(PagesCompanion(markupJson: Value(json)));

  /// User edit of the recognized text; the box layout is kept.
  Future<void> setOcrText(int pageId, String text) =>
      (update(pages)..where((p) => p.id.equals(pageId))).write(PagesCompanion(ocrText: Value(text)));

  /// Marks pages for (re-)reading.
  Future<void> clearOcr(Iterable<int> pageIds) => (update(pages)..where((p) => p.id.isIn(pageIds)))
      .write(const PagesCompanion(ocrText: Value(null), ocrJson: Value(null)));

  // ------------------------------------------------------------------ folders

  Stream<List<Folder>> watchFolders(int? parentId) {
    final q = select(folders)
      ..where((f) => parentId == null ? f.parentId.isNull() : f.parentId.equals(parentId))
      ..orderBy([(f) => OrderingTerm.asc(f.name)]);
    return q.watch();
  }

  Stream<List<Folder>> watchAllFolders() => (select(folders)..orderBy([(f) => OrderingTerm.asc(f.name)])).watch();

  Stream<Folder?> watchFolder(int id) => (select(folders)..where((f) => f.id.equals(id))).watchSingleOrNull();

  /// Live document count per folder (null key = top level).
  Stream<Map<int?, int>> watchFolderCounts() {
    final count = documents.id.count();
    final q = selectOnly(documents)
      ..addColumns([documents.folderId, count])
      ..where(documents.deletedAt.isNull())
      ..groupBy([documents.folderId]);
    return q.watch().map((rows) => {for (final r in rows) r.read(documents.folderId): r.read(count) ?? 0});
  }

  Future<int> createFolder(String name, {int? parentId}) =>
      into(folders).insert(FoldersCompanion.insert(name: name, parentId: Value(parentId)));

  Future<void> renameFolder(int id, String name) =>
      (update(folders)..where((f) => f.id.equals(id))).write(FoldersCompanion(name: Value(name)));

  /// [id] and every folder below it.
  Future<List<int>> folderSubtree(int id) async {
    final all = await select(folders).get();
    final children = <int?, List<int>>{};
    for (final f in all) {
      children.putIfAbsent(f.parentId, () => []).add(f.id);
    }
    final out = <int>[];
    final stack = [id];
    while (stack.isNotEmpty) {
      final cur = stack.removeLast();
      out.add(cur);
      stack.addAll(children[cur] ?? const []);
    }
    return out;
  }

  /// Deletes a folder and its subfolders. Their documents go to the
  /// recycle bin (and lose the folder, so a restore lands at top level).
  Future<void> deleteFolder(int id) => transaction(() async {
        final ids = await folderSubtree(id);
        // Live documents go to the bin; already-trashed ones keep their date.
        await (update(documents)..where((d) => d.folderId.isIn(ids) & d.deletedAt.isNull()))
            .write(DocumentsCompanion(deletedAt: Value(DateTime.now())));
        await (update(documents)..where((d) => d.folderId.isIn(ids))).write(const DocumentsCompanion(folderId: Value(null)));
        // Children first so the parent reference never dangles.
        for (final f in ids.reversed) {
          await (delete(folders)..where((t) => t.id.equals(f))).go();
        }
      });

  // --------------------------------------------------------------------- tags

  Stream<List<Tag>> watchTags() => (select(tags)..orderBy([(t) => OrderingTerm.asc(t.name)])).watch();

  Stream<List<Tag>> watchTagsOf(int documentId) {
    final q = select(tags).join([innerJoin(documentTags, documentTags.tagId.equalsExp(tags.id))])
      ..where(documentTags.documentId.equals(documentId))
      ..orderBy([OrderingTerm.asc(tags.name)]);
    return q.watch().map((rows) => [for (final r in rows) r.readTable(tags)]);
  }

  Future<List<int>> tagIdsOf(int documentId) async {
    final q = select(documentTags)..where((t) => t.documentId.equals(documentId));
    return [for (final r in await q.get()) r.tagId];
  }

  /// Returns the id of the tag called [name], creating it if needed.
  Future<int> ensureTag(String name) async {
    final existing = await (select(tags)..where((t) => t.name.equals(name))).getSingleOrNull();
    return existing?.id ?? await into(tags).insert(TagsCompanion.insert(name: name));
  }

  /// Replaces the tag set of every document in [docIds] with [tagIds].
  Future<void> setTags(Iterable<int> docIds, Set<int> tagIds) => transaction(() async {
        await (delete(documentTags)..where((t) => t.documentId.isIn(docIds))).go();
        for (final d in docIds) {
          for (final t in tagIds) {
            await into(documentTags).insert(DocumentTagsCompanion.insert(documentId: d, tagId: t));
          }
        }
      });

  Future<void> addTag(Iterable<int> docIds, int tagId) => batch((b) {
        for (final d in docIds) {
          b.insert(documentTags, DocumentTagsCompanion.insert(documentId: d, tagId: tagId), mode: InsertMode.insertOrIgnore);
        }
      });

  Future<void> renameTag(int id, String name) =>
      (update(tags)..where((t) => t.id.equals(id))).write(TagsCompanion(name: Value(name)));

  Future<void> deleteTag(int id) => (delete(tags)..where((t) => t.id.equals(id))).go();

  // ----------------------------------------------------------------- settings

  Future<String?> getSetting(String key) async =>
      (await (select(settings)..where((s) => s.key.equals(key))).getSingleOrNull())?.value;

  Future<void> setSetting(String key, String? value) => value == null
      ? (delete(settings)..where((s) => s.key.equals(key))).go()
      : into(settings).insertOnConflictUpdate(SettingsCompanion.insert(key: key, value: value));
}
