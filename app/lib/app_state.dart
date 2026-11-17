import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/app_lock.dart';
import 'data/db.dart';
import 'data/page_store.dart';
import 'ocr/ocr_queue.dart';
import 'ocr/ocr_service.dart';

/// Overridden in main() once the database and storage are opened.
final dbProvider = Provider<AppDatabase>((ref) => throw UnimplementedError());
final storeProvider = Provider<PageStore>((ref) => throw UnimplementedError());

final appLockProvider = Provider<AppLock>((ref) => AppLock(ref.watch(dbProvider)));

/// The OCR worker, started on first use. A failed start is remembered (so
/// the queue does not retry it for every page) until the provider is
/// invalidated.
final ocrEngineProvider = FutureProvider<OcrEngine>((ref) async {
  final service = await OcrService.start();
  ref.onDispose(service.dispose);
  return service;
});

/// The OCR engine, restarted if its worker died (otherwise the dead
/// service would stay cached until the app restarts).
Future<OcrEngine> liveOcrEngine(Ref ref) async {
  final e = await ref.read(ocrEngineProvider.future);
  if (e is OcrService && e.isClosed) {
    ref.invalidate(ocrEngineProvider);
    return ref.read(ocrEngineProvider.future);
  }
  return e;
}

/// Layout / table models for document conversion; the same worker as OCR.
final layoutEngineProvider = FutureProvider<LayoutEngine>((ref) async {
  final engine = await ref.watch(ocrEngineProvider.future);
  if (engine is LayoutEngine) return engine as LayoutEngine;
  throw StateError('版面分析不可用');
});

const ocrAutoKey = 'ocr.auto';

final ocrQueueProvider = Provider<OcrQueue>((ref) {
  final q = OcrQueue(ref.watch(dbProvider), ref.watch(storeProvider), () => liveOcrEngine(ref));
  ref.onDispose(q.dispose);
  return q;
});

final ocrPendingProvider = StreamProvider<int>((ref) => ref.watch(dbProvider).watchOcrPendingCount());

final pageProvider = StreamProvider.family<ScanPage?, int>((ref, id) => ref.watch(dbProvider).watchPage(id));

/// What a document list shows: one folder's contents, or (with a tag)
/// every document carrying that tag.
typedef DocQuery = ({int? folderId, int? tagId, DocSort sort});

final documentsProvider = StreamProvider.family<List<Document>, DocQuery>(
  (ref, q) => ref.watch(dbProvider).watchDocuments(folderId: q.folderId, tagId: q.tagId, sort: q.sort),
);

final pagesProvider = StreamProvider.family<List<ScanPage>, int>(
  (ref, docId) => ref.watch(dbProvider).watchPages(docId),
);

final documentProvider = StreamProvider.family<Document?, int>(
  (ref, docId) => ref.watch(dbProvider).watchDocument(docId),
);

final foldersProvider = StreamProvider.family<List<Folder>, int?>(
  (ref, parentId) => ref.watch(dbProvider).watchFolders(parentId),
);

final allFoldersProvider = StreamProvider<List<Folder>>((ref) => ref.watch(dbProvider).watchAllFolders());

final folderProvider = StreamProvider.family<Folder?, int>((ref, id) => ref.watch(dbProvider).watchFolder(id));

final folderCountsProvider = StreamProvider<Map<int?, int>>((ref) => ref.watch(dbProvider).watchFolderCounts());

final tagsProvider = StreamProvider<List<Tag>>((ref) => ref.watch(dbProvider).watchTags());

final tagsOfProvider = StreamProvider.family<List<Tag>, int>((ref, docId) => ref.watch(dbProvider).watchTagsOf(docId));

final recentProvider = StreamProvider<List<Document>>((ref) => ref.watch(dbProvider).watchRecent());

final trashProvider = StreamProvider<List<Document>>((ref) => ref.watch(dbProvider).watchTrash());

enum ViewMode {
  list('列表'),
  grid('网格'),
  large('大图');

  const ViewMode(this.label);
  final String label;
}

typedef LibraryPrefs = ({ViewMode view, DocSort sort});

/// View mode and sort order, remembered in the settings table.
class LibraryPrefsNotifier extends Notifier<LibraryPrefs> {
  static const _viewKey = 'ui.view', _sortKey = 'ui.sort';

  @override
  LibraryPrefs build() {
    _load();
    return (view: ViewMode.list, sort: DocSort.updated);
  }

  Future<void> _load() async {
    final db = ref.read(dbProvider);
    final v = await db.getSetting(_viewKey), s = await db.getSetting(_sortKey);
    state = (
      view: ViewMode.values.firstWhere((e) => e.name == v, orElse: () => ViewMode.list),
      sort: DocSort.values.firstWhere((e) => e.name == s, orElse: () => DocSort.updated),
    );
  }

  void setView(ViewMode v) {
    state = (view: v, sort: state.sort);
    ref.read(dbProvider).setSetting(_viewKey, v.name);
  }

  void setSort(DocSort s) {
    state = (view: state.view, sort: s);
    ref.read(dbProvider).setSetting(_sortKey, s.name);
  }
}

final libraryPrefsProvider = NotifierProvider<LibraryPrefsNotifier, LibraryPrefs>(LibraryPrefsNotifier.new);
