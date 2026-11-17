import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../markup/geometry.dart';
import '../markup/markup.dart';
import '../markup/watermark.dart';
import '../scan/image_ops.dart';
import '../scan/quad.dart';
import 'db.dart';
import 'temp_files.dart';
import '../scan/background.dart';

/// A captured page before it is saved: the original photo plus the
/// edit settings the user chose.
class DraftPage {
  DraftPage({
    required this.original,
    required this.width,
    required this.height,
    this.quad,
    this.detected,
    this.filter = ScanFilter.enhance,
    this.rotation = 0,
  });

  factory DraftPage.fromPrepared(PreparedImage p) =>
      DraftPage(original: p.bytes, width: p.width, height: p.height, quad: p.quad, detected: p.quad);

  /// Auto-detected outline, kept so the crop editor can offer a reset.
  final Quad? detected;

  /// EXIF-free JPEG produced by [ImageOps.prepare].
  final Uint8List original;
  final int width;
  final int height;
  Quad? quad;
  ScanFilter filter;
  int rotation;
}

/// Owns the on-disk page images and keeps them in sync with the database.
class PageStore {
  PageStore(this.db, this.dir);

  final AppDatabase db;
  final Directory dir;
  static const _uuid = Uuid();

  static Future<PageStore> open(AppDatabase db) async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'pages'));
    await dir.create(recursive: true);
    return PageStore(db, dir);
  }

  File file(String name) => File(p.join(dir.path, name));

  Future<int> createDocument(String title, List<DraftPage> drafts, {int? folderId}) async {
    final docId = await db
        .into(db.documents)
        .insert(DocumentsCompanion.insert(title: title, folderId: Value(folderId)));
    await appendPages(docId, drafts);
    return docId;
  }

  Future<void> appendPages(int docId, List<DraftPage> drafts) => insertPages(docId, drafts);

  /// Inserts [drafts] so the first one lands at index [at] (0-based, in
  /// the current page order); null appends at the end.
  Future<void> insertPages(int docId, List<DraftPage> drafts, {int? at}) async {
    if (drafts.isEmpty) return;
    // Render and write files first; only touch the database once every
    // image is on disk, so a failure leaves the document unchanged.
    final rendered = <(DraftPage, String, String, String)>[];
    try {
      for (final d in drafts) {
        final id = _uuid.v4();
        final orig = '$id.orig.jpg';
        await file(orig).writeAsBytes(d.original, flush: true);
        final (proc, thumb) = await _render(id, d.original, d.quad, d.filter, d.rotation);
        rendered.add((d, orig, proc, thumb));
      }
    } catch (_) {
      for (final r in rendered) {
        await _deleteQuietly([r.$2, r.$3, r.$4]);
      }
      rethrow;
    }
    await db.transaction(() async {
      final existing = await db.pagesOf(docId);
      final insertAt = (at ?? existing.length).clamp(0, existing.length);
      // Renumber every existing page (deletions leave gaps) so positions
      // become a dense 0..n-1 sequence with room for the new pages.
      for (var i = 0; i < existing.length; i++) {
        final pos = i < insertAt ? i : i + rendered.length;
        if (existing[i].position == pos) continue;
        await (db.update(
          db.pages,
        )..where((t) => t.id.equals(existing[i].id))).write(PagesCompanion(position: Value(pos)));
      }
      for (var k = 0; k < rendered.length; k++) {
        final (d, orig, proc, thumb) = rendered[k];
        await db
            .into(db.pages)
            .insert(
              PagesCompanion.insert(
                documentId: docId,
                position: insertAt + k,
                originalFile: orig,
                processedFile: proc,
                thumbFile: thumb,
                quadJson: Value(d.quad == null ? null : jsonEncode(d.quad!.toJson())),
                filter: Value(d.filter.name),
                rotation: Value(d.rotation),
              ),
            );
      }
    });
    await db.touch(docId);
  }

  /// Retake: swaps in a new photo for [page], keeping its position. The
  /// new draft's own crop, filter and rotation are used.
  Future<void> replacePage(ScanPage page, DraftPage d) async {
    final id = _uuid.v4();
    final orig = '$id.orig.jpg';
    await file(orig).writeAsBytes(d.original, flush: true);
    final (String, String) files;
    try {
      files = await _render(id, d.original, d.quad, d.filter, d.rotation);
    } catch (_) {
      await _deleteQuietly([orig]);
      rethrow;
    }
    final (proc, thumb) = files;
    await (db.update(db.pages)..where((t) => t.id.equals(page.id))).write(
      PagesCompanion(
        originalFile: Value(orig),
        processedFile: Value(proc),
        thumbFile: Value(thumb),
        quadJson: Value(d.quad == null ? null : jsonEncode(d.quad!.toJson())),
        filter: Value(d.filter.name),
        rotation: Value(d.rotation),
        // A new photo: the old text and markup no longer apply.
        ocrText: const Value(null),
        ocrJson: const Value(null),
        markupJson: const Value(null),
      ),
    );
    await _deleteQuietly([page.originalFile, page.processedFile, page.thumbFile, ...markupFiles(page)]);
    await db.touch(page.documentId);
  }

  /// Re-renders a page after the user changes crop, filter or rotation.
  Future<void> updatePage(
    ScanPage page, {
    Quad? quad,
    ScanFilter? filter,
    int? rotation,
    bool clearQuad = false,
  }) async {
    final original = await file(page.originalFile).readAsBytes();
    final q = clearQuad ? null : (quad ?? quadOf(page));
    final f = filter ?? filterOf(page);
    final r = rotation ?? page.rotation;
    final id = _uuid.v4();
    final (proc, thumb) = await _render(id, original, q, f, r);
    // Crop and rotation move the text, so the stored boxes would be wrong;
    // a filter change keeps the geometry and the recognized text.
    final geometryChanged = r != page.rotation || jsonEncode(q?.toJson()) != jsonEncode(quadOf(page)?.toJson());
    // Markup is carried over to the new crop instead: it stays on the same
    // words of the photo.
    String? markup = page.markupJson;
    try {
      if (geometryChanged && markup != null) {
        final size = await _originalSize(original);
        final from = PageGeometry(
          originalWidth: size.$1,
          originalHeight: size.$2,
          quad: quadOf(page),
          rotation: page.rotation,
        );
        final to = PageGeometry(originalWidth: size.$1, originalHeight: size.$2, quad: q, rotation: r);
        markup = PageMarkup.parse(markup).remapped(from, to).toJsonString();
      }
    } catch (_) {
      await _deleteQuietly([proc, thumb]);
      rethrow;
    }
    await (db.update(db.pages)..where((t) => t.id.equals(page.id))).write(
      PagesCompanion(
        processedFile: Value(proc),
        thumbFile: Value(thumb),
        quadJson: Value(q == null ? null : jsonEncode(q.toJson())),
        filter: Value(f.name),
        rotation: Value(r),
        ocrText: geometryChanged ? const Value(null) : const Value.absent(),
        ocrJson: geometryChanged ? const Value(null) : const Value.absent(),
        markupJson: geometryChanged ? Value(markup) : const Value.absent(),
      ),
    );
    await _deleteQuietly([page.processedFile, page.thumbFile]);
    await db.touch(page.documentId);
  }

  Future<void> deletePage(ScanPage page) async {
    await (db.delete(db.pages)..where((t) => t.id.equals(page.id))).go();
    await _deleteQuietly([page.originalFile, page.processedFile, page.thumbFile, ...markupFiles(page)]);
    await db.touch(page.documentId);
  }

  static Iterable<String> markupFiles(ScanPage page) => PageMarkup.parse(page.markupJson).imageFiles;

  Future<(int, int)> _originalSize(Uint8List original) async =>
      jpegSize(original) ?? await jpegSizeInBackground(original);

  /// Geometry of [page]: how its processed image maps onto the photo.
  Future<PageGeometry> geometryOf(ScanPage page) async {
    final size = await _originalSize(await file(page.originalFile).readAsBytes());
    return PageGeometry(originalWidth: size.$1, originalHeight: size.$2, quad: quadOf(page), rotation: page.rotation);
  }

  /// Stores a markup image (signature, stamp) for one page and returns its
  /// file name for MarkupItem.image. Each placement gets its own copy, so
  /// deleting a signature from the library never breaks a page.
  Future<String> addMarkupImage(Uint8List png) async {
    final name = '${_uuid.v4()}.mark.png';
    await file(name).writeAsBytes(png, flush: true);
    return name;
  }

  Future<void> setMarkup(ScanPage page, PageMarkup markup) async {
    final current = await db.pageById(page.id) ?? page;
    final before = PageMarkup.parse(current.markupJson).imageFiles.toSet();
    await db.setMarkup(page.id, markup.toJsonString());
    // Signature copies no longer referenced by the page.
    await _deleteQuietly(before.difference(markup.imageFiles.toSet()).toList());
    await db.touch(page.documentId);
  }

  /// Stores a watermark image for a document.
  Future<String> addWatermarkImage(Uint8List png) async {
    final name = '${_uuid.v4()}.wm.png';
    await file(name).writeAsBytes(png, flush: true);
    return name;
  }

  Future<void> setWatermark(Document doc, Watermark? w) async {
    final old = Watermark.parse(doc.watermarkJson)?.image;
    await db.setWatermark(doc.id, w?.toJsonString());
    if (old != null && old != w?.image) await _deleteQuietly([old]);
    await db.touch(doc.id);
  }

  /// Permanently blacks out [areas] (processed-image pixels) in the page.
  ///
  /// The areas are mapped back onto the original photo and painted black
  /// there, then the page is re-rendered, so the content is gone from every
  /// file the app keeps, not just covered in exports. The recognized text
  /// is cleared so it is read again without the removed words.
  Future<void> redact(ScanPage page, List<Rect> areas) async {
    if (areas.isEmpty) return;
    final original = await file(page.originalFile).readAsBytes();
    final size = await _originalSize(original);
    final g = PageGeometry(
      originalWidth: size.$1,
      originalHeight: size.$2,
      quad: quadOf(page),
      rotation: page.rotation,
    );
    final polys = [
      for (final r in areas)
        [
          for (final p in [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft])
            (g.toOriginal(p).dx, g.toOriginal(p).dy),
        ],
    ];
    final redacted = await blackOutInBackground(original, polys);
    final id = _uuid.v4();
    final orig = '$id.orig.jpg';
    await file(orig).writeAsBytes(redacted, flush: true);
    final (String, String) files;
    try {
      files = await _render(id, redacted, quadOf(page), filterOf(page), page.rotation);
    } catch (_) {
      await _deleteQuietly([orig]);
      rethrow;
    }
    await (db.update(db.pages)..where((t) => t.id.equals(page.id))).write(
      PagesCompanion(
        originalFile: Value(orig),
        processedFile: Value(files.$1),
        thumbFile: Value(files.$2),
        ocrText: const Value(null),
        ocrJson: const Value(null),
      ),
    );
    await _deleteQuietly([page.originalFile, page.processedFile, page.thumbFile]);
    await db.touch(page.documentId);
    // Reader / share copies made before still contain what was removed.
    await TempFiles.forgetDocument(page.documentId);
  }

  Future<void> reorder(int docId, List<ScanPage> ordered) async {
    await db.transaction(() async {
      for (var i = 0; i < ordered.length; i++) {
        await (db.update(db.pages)..where((t) => t.id.equals(ordered[i].id))).write(PagesCompanion(position: Value(i)));
      }
    });
    await db.touch(docId);
  }

  /// Removes a document and its image files permanently.
  Future<void> purgeDocument(int docId) async {
    final pages = await db.pagesOf(docId);
    final wm = Watermark.parse((await db.documentById(docId))?.watermarkJson)?.image;
    await (db.delete(db.documents)..where((d) => d.id.equals(docId))).go();
    for (final pg in pages) {
      await _deleteQuietly([pg.originalFile, pg.processedFile, pg.thumbFile, ...markupFiles(pg)]);
    }
    if (wm != null) await _deleteQuietly([wm]);
    await TempFiles.forgetDocument(docId);
  }

  /// How long documents stay in the recycle bin.
  static const trashRetention = Duration(days: 30);

  /// Permanently deletes recycle-bin documents older than [trashRetention].
  /// Returns how many were removed.
  Future<int> purgeExpiredTrash({DateTime? now}) async {
    final ids = await db.trashedBefore((now ?? DateTime.now()).subtract(trashRetention));
    for (final id in ids) {
      await purgeDocument(id);
    }
    return ids.length;
  }

  /// Duplicates a document with its own copies of every image file, its
  /// tags and lock state. Returns the new document's id.
  /// Copies one page's files (photo, page, thumbnail, signature images)
  /// and returns the row for the copy at [position]; created file names are
  /// added to [copied] so a failed operation can remove them.
  Future<PagesCompanion> _copyPage(ScanPage pg, int position, List<String> copied) async {
    final id = _uuid.v4();
    final names = ('$id.orig.jpg', '$id.jpg', '$id.thumb.jpg');
    await file(pg.originalFile).copy(file(names.$1).path);
    copied.add(names.$1);
    await file(pg.processedFile).copy(file(names.$2).path);
    copied.add(names.$2);
    await file(pg.thumbFile).copy(file(names.$3).path);
    copied.add(names.$3);
    // Signatures are owned per page: give the copy its own files.
    var markup = PageMarkup.parse(pg.markupJson);
    if (markup.imageFiles.isNotEmpty) {
      final renamed = <MarkupItem>[];
      for (final item in markup.items) {
        if (item.image == null) {
          renamed.add(item);
          continue;
        }
        final n = '${_uuid.v4()}.mark.png';
        try {
          await file(item.image!).copy(file(n).path);
        } on FileSystemException {
          continue; // file lost: the copy simply lacks that signature
        }
        copied.add(n);
        renamed.add(item.withImage(n));
      }
      markup = PageMarkup(renamed);
    }
    return PagesCompanion.insert(
      documentId: 0, // set by the caller
      position: position,
      originalFile: names.$1,
      processedFile: names.$2,
      thumbFile: names.$3,
      quadJson: Value(pg.quadJson),
      filter: Value(pg.filter),
      rotation: Value(pg.rotation),
      ocrText: Value(pg.ocrText),
      ocrJson: Value(pg.ocrJson),
      markupJson: Value(markup.toJsonString()),
    );
  }

  /// Creates a document holding copies of [pages] (in that order) and
  /// returns its id. Nothing is written to the database unless every file
  /// was copied.
  Future<int> _newDocumentFrom(
    List<ScanPage> pages, {
    required String title,
    int? folderId,
    bool locked = false,
    Document? watermarkFrom,
    Set<int> tags = const {},
  }) async {
    final copied = <String>[];
    final rows = <PagesCompanion>[];
    String? watermark;
    try {
      for (var i = 0; i < pages.length; i++) {
        rows.add(await _copyPage(pages[i], i, copied));
      }
      var wm = Watermark.parse(watermarkFrom?.watermarkJson);
      if (wm?.image != null) {
        final n = '${_uuid.v4()}.wm.png';
        try {
          await file(wm!.image!).copy(file(n).path);
          copied.add(n);
          wm = wm.copyWith(image: n);
        } on FileSystemException {
          wm = null;
        }
      }
      watermark = wm?.toJsonString();
    } catch (_) {
      await _deleteQuietly(copied);
      rethrow;
    }
    final t = title.trim().isEmpty ? '新文档' : title.trim();
    try {
      return await db.transaction(() async {
        final newId = await db
            .into(db.documents)
            .insert(
              DocumentsCompanion.insert(
                title: t.length > 200 ? t.substring(0, 200) : t,
                folderId: Value(folderId),
                locked: Value(locked),
                watermarkJson: Value(watermark),
              ),
            );
        for (final row in rows) {
          await db.into(db.pages).insert(row.copyWith(documentId: Value(newId)));
        }
        if (tags.isNotEmpty) await db.setTags([newId], tags);
        return newId;
      });
    } catch (_) {
      await _deleteQuietly(copied);
      rethrow;
    }
  }

  /// Duplicates a document with its own copies of every image file, its
  /// tags, watermark and lock state. Returns the new document's id.
  Future<int> copyDocument(int docId, {String suffix = ' 副本'}) async {
    final src = await db.documentById(docId);
    if (src == null) throw StateError('文档不存在');
    return _newDocumentFrom(
      await db.pagesOf(docId),
      title: '${src.title}$suffix',
      folderId: src.folderId,
      locked: src.locked,
      watermarkFrom: src,
      tags: (await db.tagIdsOf(docId)).toSet(),
    );
  }

  /// Joins documents (in the given order) into a new one; the originals
  /// stay. It goes into the first document's folder, locked if any source
  /// was locked, with all their tags.
  Future<int> mergeDocuments(List<int> docIds, {required String title}) async {
    if (docIds.length < 2) throw ArgumentError('至少要两个文档');
    final pages = <ScanPage>[];
    final tags = <int>{};
    Document? first;
    var locked = false;
    for (final id in docIds) {
      final d = await db.documentById(id);
      if (d == null) continue;
      first ??= d;
      locked |= d.locked;
      pages.addAll(await db.pagesOf(id));
      tags.addAll(await db.tagIdsOf(id));
    }
    if (pages.isEmpty) throw StateError('没有页面可合并');
    return _newDocumentFrom(pages, title: title, folderId: first?.folderId, locked: locked, tags: tags);
  }

  /// Copies [pageIds] (in page order) into a new document next to the
  /// source. With [move] they are then removed from the source (a split).
  /// Returns the new document's id.
  Future<int> extractPages(int docId, Set<int> pageIds, {required String title, bool move = false}) async {
    final src = await db.documentById(docId);
    if (src == null) throw StateError('文档不存在');
    final all = await db.pagesOf(docId);
    final picked = [
      for (final p in all)
        if (pageIds.contains(p.id)) p,
    ];
    if (picked.isEmpty) throw ArgumentError('没有选中页面');
    if (move && picked.length == all.length) throw StateError('不能把所有页都移走');
    final newId = await _newDocumentFrom(
      picked,
      title: title,
      folderId: src.folderId,
      locked: src.locked,
      watermarkFrom: src,
      tags: (await db.tagIdsOf(docId)).toSet(),
    );
    if (move) {
      // All rows in one transaction, so a failure cannot leave some moved
      // pages in both documents; files only after it committed.
      await db.transaction(() async {
        await (db.delete(db.pages)..where((t) => t.id.isIn(picked.map((p) => p.id)))).go();
        final rest = await db.pagesOf(docId);
        for (var i = 0; i < rest.length; i++) {
          if (rest[i].position != i) {
            await (db.update(
              db.pages,
            )..where((t) => t.id.equals(rest[i].id))).write(PagesCompanion(position: Value(i)));
          }
        }
      });
      for (final p in picked) {
        await _deleteQuietly([p.originalFile, p.processedFile, p.thumbFile, ...markupFiles(p)]);
      }
      await db.touch(docId);
    }
    return newId;
  }

  static Quad? quadOf(ScanPage page) =>
      page.quadJson == null ? null : Quad.fromJson(jsonDecode(page.quadJson!) as Map<String, dynamic>);

  static ScanFilter filterOf(ScanPage page) =>
      ScanFilter.values.firstWhere((f) => f.name == page.filter, orElse: () => ScanFilter.enhance);

  Future<(String, String)> _render(String id, Uint8List original, Quad? quad, ScanFilter filter, int rotation) async {
    final (procBytes, thumbBytes) = await renderPageInBackground(original, quad, filter, rotation);
    final proc = '$id.jpg';
    final thumb = '$id.thumb.jpg';
    await file(proc).writeAsBytes(procBytes, flush: true);
    await file(thumb).writeAsBytes(thumbBytes, flush: true);
    return (proc, thumb);
  }

  Future<void> _deleteQuietly(List<String> names) async {
    for (final n in names) {
      try {
        await file(n).delete();
      } on FileSystemException {
        // Already gone; nothing to clean up.
      }
    }
  }
}
