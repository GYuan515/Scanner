import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:printing/printing.dart';

import '../app_state.dart';
import '../data/db.dart';
import '../data/exporter.dart';
import '../data/importer.dart';
import '../data/page_store.dart';
import '../markup/watermark.dart';
import 'convert_actions.dart';
import 'doc_operations.dart';
import 'library_actions.dart';
import 'page_screen.dart';
import 'pdf_options_sheet.dart';
import 'reader_screen.dart';
import 'redact_screen.dart';
import 'review_screen.dart';
import 'watermark_screen.dart';

class DocumentScreen extends ConsumerStatefulWidget {
  const DocumentScreen({super.key, required this.docId});
  final int docId;

  @override
  ConsumerState<DocumentScreen> createState() => _DocumentScreenState();
}

class _DocumentScreenState extends ConsumerState<DocumentScreen> {
  bool _working = false;

  /// Page ids picked in selection mode (long-press a page); empty = normal.
  final _picked = <int>{};

  /// Locked documents stay hidden until fingerprint/password succeeds.
  bool _unlocked = false;
  bool _unlocking = false;
  bool _autoPrompted = false;

  /// Remembered for this screen so repeated exports keep the last choice.
  PdfOptions _pdfOptions = const PdfOptions();

  @override
  void initState() {
    super.initState();
    ref.read(dbProvider).markOpened(widget.docId);
  }

  Future<void> _tryUnlock() async {
    if (_unlocking) return;
    _unlocking = true;
    final ok = await unlock(context, ref, reason: '打开加锁的文档');
    _unlocking = false;
    if (mounted && ok) setState(() => _unlocked = true);
  }

  Future<void> _run(String label, Future<void> Function() task) async {
    setState(() => _working = true);
    try {
      await task();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$label失败：$e')));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _rename(Document doc) async {
    final name = await promptText(context, title: '重命名', initial: doc.title, maxLength: 200);
    if (name == null) return;
    await ref.read(dbProvider).renameDocument(doc.id, name);
  }

  Future<void> _delete() async {
    if (await trashDocs(context, ref, [widget.docId]) && mounted) context.pop();
  }

  Future<void> _menu(String k, Document doc) async {
    switch (k) {
      case 'rename':
        await _rename(doc);
      case 'move':
        await moveDocs(context, ref, [doc.id]);
      case 'copy':
        await _run('复制', () => copyDocs(context, ref, [doc.id]));
      case 'tags':
        await editTags(context, ref, [doc.id]);
      case 'lock':
        await toggleLock(context, ref, [doc]);
        // Removing the lock already authenticated; adding one keeps the
        // current view open.
        if (mounted) setState(() => _unlocked = true);
      case 'ocr':
        await _rereadAll();
      case 'watermark':
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => WatermarkScreen(docId: doc.id)));
      case 'redact':
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => RedactScreen(docId: doc.id)));
      case 'delete':
        await _delete();
    }
  }

  /// Reads every page without text now (exports need it), in page order.
  /// Returns the pages re-read from the database, or null if cancelled by
  /// leaving the screen.
  Future<List<ScanPage>?> _ensureOcr(List<ScanPage> pages) async {
    final queue = ref.read(ocrQueueProvider);
    final db = ref.read(dbProvider);
    // Fresh rows: the queue may have read some pages since [pages] was built.
    final ids = pages.map((p) => p.id).toSet();
    final current = (await db.pagesOf(widget.docId)).where((p) => ids.contains(p.id));
    final missing = current.where((p) => p.ocrJson == null).toList();
    var failed = 0;
    for (final pg in missing) {
      try {
        await queue.readNow(pg);
      } catch (_) {
        failed++;
      }
      if (!mounted) return null;
    }
    if (failed > 0 && mounted) toast(context, '有 $failed 页识别失败，导出时没有这些页的文字');
    return (await db.pagesOf(widget.docId)).where((p) => ids.contains(p.id)).toList();
  }

  Future<void> _rereadAll() async {
    if (!await confirm(context, title: '重新识别全部页？', message: '手动修改过的文字会被新的识别结果替换。', ok: '重新识别')) return;
    final db = ref.read(dbProvider);
    final pages = await db.pagesOf(widget.docId);
    await db.clearOcr(pages.map((p) => p.id));
    ref.read(ocrQueueProvider).request(pages.map((p) => p.id));
  }

  Future<void> _export(Document doc, List<ScanPage> pages, String kind) async {
    final ex = Exporter(ref.read(storeProvider), watermark: Watermark.parse(doc.watermarkJson));
    PdfOptions? opts;
    if (kind == 'pdf' || kind == 'save') {
      opts = await askPdfOptions(context, _pdfOptions);
      if (opts == null) return;
      // Remembered for the next export, except the password.
      _pdfOptions = opts.copyWith(clearPassword: true);
    }
    if (kind == 'txt' || (opts?.searchable ?? false)) {
      List<ScanPage>? fresh;
      await _run('识别', () async => fresh = await _ensureOcr(pages));
      if (fresh == null || !mounted) return;
      pages = fresh!;
    }
    switch (kind) {
      case 'txt':
        await _run('导出', () => ex.shareText(doc.title, pages));
      case 'pdf':
        await _run('导出', () => ex.sharePdf(doc.title, pages, options: opts!));
      case 'jpg':
        await _run('导出', () => ex.shareImages(doc.title, pages));
      case 'long':
        await _run('导出', () => ex.shareLongImage(doc.title, pages));
      case 'word' || 'excel':
        if (!mounted) return;
        await convertDocument(context, ref, doc, pages, kind == 'word' ? ConvertTarget.word : ConvertTarget.excel);
        return;
      case 'print':
        await _run('打印', () async {
          final bytes = await ex.buildPdf(pages, options: const PdfOptions(size: PdfPageSize.a4, searchable: false));
          await Printing.layoutPdf(onLayout: (_) async => bytes, name: doc.title);
        });
      case 'save':
        await _run('保存', () async {
          final bytes = await ex.buildPdf(pages, options: opts!);
          final uri = await FilePicker.saveFile(
            fileName: '${Exporter.safeName(doc.title)}.pdf',
            bytes: bytes,
            mimeType: 'application/pdf',
          );
          if (uri != null && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已保存')));
          }
        });
    }
  }

  // ------------------------------------------------------------ add pages

  /// Adds pages from the camera, the gallery or files; [at] inserts them
  /// before that page index, null appends. Imported pages go through the
  /// same review (crop, filter) as camera shots.
  Future<void> _addPages({int? at}) async {
    final source = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(title: Text(at == null ? '添加页' : '插入页')),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('拍照'),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选择'),
              onTap: () => Navigator.pop(ctx, 'gallery'),
            ),
            ListTile(
              leading: const Icon(Icons.file_open_outlined),
              title: const Text('从文件导入'),
              subtitle: const Text('图片或 PDF'),
              onTap: () => Navigator.pop(ctx, 'files'),
            ),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;
    if (source == 'camera') {
      context.push(at == null ? '/scan?doc=${widget.docId}' : '/scan?doc=${widget.docId}&at=$at');
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    void busy() => messenger.showSnackBar(const SnackBar(content: Text('正在处理…'), duration: Duration(minutes: 5)));
    ImportResult? result;
    try {
      result = source == 'files'
          ? await Importer.fromFiles(onPicked: busy)
          : await Importer.fromGallery(onPicked: busy);
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text('导入失败：$e')));
      return;
    }
    messenger.hideCurrentSnackBar();
    if (result == null) return;
    if (result.failed.isNotEmpty) {
      messenger.showSnackBar(SnackBar(content: Text('${result.failed.length} 个文件无法读取，已跳过：${result.failed.join('、')}')));
    }
    if (result.drafts.isEmpty || !mounted) return;
    await Navigator.of(context).push<int>(
      MaterialPageRoute(
        builder: (_) => ReviewScreen(drafts: result!.drafts, appendTo: widget.docId, insertAt: at),
      ),
    );
  }

  // ------------------------------------------------------- page selection

  Future<void> _rotatePicked(List<ScanPage> pages) => _run('旋转', () async {
    final store = ref.read(storeProvider);
    // Fixed up front: ticking boxes meanwhile must not change the set.
    final targets = pages.where((p) => _picked.contains(p.id)).toList();
    for (final pg in targets) {
      await store.updatePage(pg, rotation: (pg.rotation + 1) % 4);
    }
  });

  Future<void> _deletePicked(List<ScanPage> pages) async {
    final n = _picked.length;
    if (n == pages.length) {
      toast(context, '不能删掉所有页；要删整个文档请用菜单里的“删除”');
      return;
    }
    if (!await confirm(context, title: '删除 $n 页？', message: '这些页会被永久删除。', ok: '删除')) return;
    final targets = pages.where((p) => _picked.contains(p.id)).toList();
    await _run('删除', () async {
      final store = ref.read(storeProvider);
      for (final pg in targets) {
        await store.deletePage(pg);
      }
      await store.reorder(widget.docId, await ref.read(dbProvider).pagesOf(widget.docId));
    });
    if (mounted) setState(_picked.clear);
  }

  /// Copies ([move] false) or moves the picked pages into a new document.
  Future<void> _extractPicked(Document doc, List<ScanPage> pages, {required bool move}) async {
    if (move && _picked.length == pages.length) {
      toast(context, '不能把所有页都拆出去');
      return;
    }
    final title = await promptText(
      context,
      title: move ? '拆分出的新文档' : '提取为新文档',
      initial: '${doc.title} 摘录',
      maxLength: 200,
    );
    if (title == null || !mounted) return;
    int? newId;
    final ids = {..._picked};
    await _run(move ? '拆分' : '提取', () async {
      newId = await ref.read(storeProvider).extractPages(widget.docId, ids, title: title, move: move);
    });
    if (newId == null || !mounted) return;
    setState(_picked.clear);
    toast(context, move ? '已拆分为新文档“$title”' : '已提取为新文档“$title”');
  }

  PreferredSizeWidget _selectionBar(Document doc, List<ScanPage> pages) => AppBar(
    leading: IconButton(icon: const Icon(Icons.close), onPressed: () => setState(_picked.clear)),
    title: Text('已选 ${_picked.length} 页'),
    actions: [
      IconButton(
        tooltip: '全选',
        icon: const Icon(Icons.select_all),
        onPressed: () => setState(() => _picked.addAll(pages.map((p) => p.id))),
      ),
      IconButton(
        tooltip: '旋转',
        icon: const Icon(Icons.rotate_right),
        onPressed: _working ? null : () => _rotatePicked(pages),
      ),
      IconButton(
        tooltip: '删除',
        icon: const Icon(Icons.delete_outline),
        onPressed: _working ? null : () => _deletePicked(pages),
      ),
      PopupMenuButton<String>(
        enabled: !_working,
        onSelected: (k) => _extractPicked(doc, pages, move: k == 'split'),
        itemBuilder: (_) => const [
          PopupMenuItem(
            value: 'extract',
            child: ListTile(leading: Icon(Icons.copy_all), title: Text('提取为新文档'), subtitle: Text('原文档保留这些页')),
          ),
          PopupMenuItem(
            value: 'split',
            child: ListTile(leading: Icon(Icons.call_split), title: Text('拆分为新文档'), subtitle: Text('从原文档移走这些页')),
          ),
        ],
      ),
    ],
    bottom: _working ? const PreferredSize(preferredSize: Size.fromHeight(4), child: LinearProgressIndicator()) : null,
  );

  static String _snippet(String? t) {
    final s = (t ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
    return s.isEmpty ? '没有文字' : s;
  }

  @override
  Widget build(BuildContext context) {
    final pagesAsync = ref.watch(pagesProvider(widget.docId));
    final store = ref.read(storeProvider);
    final doc = ref.watch(documentProvider(widget.docId)).value;
    final pages = pagesAsync.value ?? const <ScanPage>[];
    final tags = ref.watch(tagsOfProvider(widget.docId)).value ?? const <Tag>[];

    if (doc != null && doc.locked && !_unlocked) {
      // Ask once automatically; after a cancel the button asks again.
      if (!_autoPrompted) {
        _autoPrompted = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_unlocked) _tryUnlock();
        });
      }
      return Scaffold(
        appBar: AppBar(title: Text(doc.title, overflow: TextOverflow.ellipsis)),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_outline, size: 56),
              const SizedBox(height: 12),
              const Text('这个文档已加锁'),
              const SizedBox(height: 12),
              FilledButton.icon(onPressed: _tryUnlock, icon: const Icon(Icons.fingerprint), label: const Text('解锁')),
            ],
          ),
        ),
      );
    }

    // Pages deleted elsewhere drop out of the selection.
    if (pagesAsync.hasValue) _picked.retainAll(pages.map((p) => p.id));
    final selecting = _picked.isNotEmpty && doc != null;

    // Back while selecting clears the selection instead of leaving.
    return PopScope(
      canPop: !selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(_picked.clear);
      },
      child: Scaffold(
        appBar: selecting
            ? _selectionBar(doc, pages)
            : AppBar(
                title: GestureDetector(
                  onTap: doc == null ? null : () => _rename(doc),
                  child: Text(doc?.title ?? '', overflow: TextOverflow.ellipsis),
                ),
                actions: [
                  if (doc != null && pages.isNotEmpty)
                    IconButton(
                      tooltip: '阅读',
                      icon: const Icon(Icons.chrome_reader_mode_outlined),
                      onPressed: () =>
                          Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReaderScreen(docId: doc.id))),
                    ),
                  if (doc != null && pages.isNotEmpty)
                    PopupMenuButton<String>(
                      icon: const Icon(Icons.ios_share),
                      enabled: !_working,
                      onSelected: (k) => _export(doc, pages, k),
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'pdf', child: Text('分享 PDF')),
                        PopupMenuItem(value: 'jpg', child: Text('分享图片')),
                        PopupMenuItem(value: 'long', child: Text('分享长图')),
                        PopupMenuItem(value: 'save', child: Text('保存 PDF 到…')),
                        PopupMenuItem(value: 'txt', child: Text('导出文字 (TXT)')),
                      PopupMenuItem(value: 'word', child: Text('转为 Word')),
                      PopupMenuItem(value: 'excel', child: Text('转为 Excel（表格）')),
                        PopupMenuItem(value: 'print', child: Text('打印')),
                      ],
                    ),
                  if (doc != null)
                    PopupMenuButton<String>(
                      enabled: !_working,
                      onSelected: (k) => _menu(k, doc),
                      itemBuilder: (_) => [
                        const PopupMenuItem(value: 'rename', child: Text('重命名')),
                        const PopupMenuItem(value: 'move', child: Text('移动到…')),
                        const PopupMenuItem(value: 'copy', child: Text('复制一份')),
                        const PopupMenuItem(value: 'tags', child: Text('标签')),
                        const PopupMenuItem(value: 'ocr', child: Text('重新识别文字')),
                        const PopupMenuItem(value: 'watermark', child: Text('水印')),
                        const PopupMenuItem(value: 'redact', child: Text('脱敏（涂黑）')),
                        PopupMenuItem(value: 'lock', child: Text(doc.locked ? '取消加锁' : '加锁')),
                        const PopupMenuItem(value: 'delete', child: Text('删除')),
                      ],
                    ),
                ],
                bottom: _working
                    ? const PreferredSize(preferredSize: Size.fromHeight(4), child: LinearProgressIndicator())
                    : null,
              ),
        body: pages.isEmpty
            ? const Center(child: Text('没有页面'))
            : ReorderableListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                header: tags.isEmpty || doc == null
                    ? null
                    : Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Wrap(
                          spacing: 6,
                          children: [
                            for (final t in tags)
                              ActionChip(label: Text('#${t.name}'), onPressed: () => editTags(context, ref, [doc.id])),
                          ],
                        ),
                      ),
                itemCount: pages.length,
                // Drag only by the handle, so long-press can start selection.
                buildDefaultDragHandles: false,
                onReorderItem: (from, to) {
                  final list = [...pages];
                  list.insert(to, list.removeAt(from));
                  store.reorder(widget.docId, list);
                },
                itemBuilder: (_, i) {
                  final pg = pages[i];
                  final picked = _picked.contains(pg.id);
                  void toggle() => setState(() => picked ? _picked.remove(pg.id) : _picked.add(pg.id));
                  return Card(
                    key: ValueKey(pg.id),
                    clipBehavior: Clip.antiAlias,
                    color: picked ? Theme.of(context).colorScheme.primaryContainer : null,
                    child: InkWell(
                      onTap: selecting
                          ? toggle
                          : () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => PageScreen(docId: widget.docId, initialIndex: i),
                              ),
                            ),
                      onLongPress: toggle,
                      child: Row(
                        children: [
                          if (selecting)
                            Padding(
                              padding: const EdgeInsets.only(left: 4),
                              child: Checkbox(value: picked, onChanged: (_) => toggle()),
                            ),
                          Image.file(
                            File(store.file(pg.thumbFile).path),
                            width: 90,
                            height: 120,
                            fit: BoxFit.cover,
                            cacheWidth: 240,
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('第 ${i + 1} 页 · ${PageStore.filterOf(pg).label}'),
                                const SizedBox(height: 4),
                                Text(
                                  pg.ocrJson == null ? '文字识别中…' : _snippet(pg.ocrText),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                          if (!selecting)
                            PopupMenuButton<int>(
                              tooltip: '插入页',
                              icon: const Icon(Icons.more_vert),
                              // Value is the index the new pages go to.
                              onSelected: (at) => _addPages(at: at),
                              itemBuilder: (_) => [
                                PopupMenuItem(value: i, child: const Text('在此页前插入')),
                                PopupMenuItem(value: i + 1, child: const Text('在此页后插入')),
                              ],
                            ),
                          ReorderableDragStartListener(
                            index: i,
                            child: const Padding(
                              padding: EdgeInsets.fromLTRB(4, 12, 12, 12),
                              child: Icon(Icons.drag_handle),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
        floatingActionButton: selecting
            ? null
            : FloatingActionButton.extended(
                onPressed: () => _addPages(),
                icon: const Icon(Icons.add_a_photo_outlined),
                label: const Text('添加页'),
              ),
      ),
    );
  }
}
