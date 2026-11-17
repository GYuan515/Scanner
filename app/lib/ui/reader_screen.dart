import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../app_state.dart';
import '../data/exporter.dart';
import '../data/temp_files.dart';
import '../markup/watermark.dart';
import 'library_actions.dart';

/// Reading view: the document as the PDF it would export to (markup,
/// watermark and text layer included), with search, page jump, thumbnails
/// and printing.
class ReaderScreen extends ConsumerStatefulWidget {
  const ReaderScreen({super.key, required this.docId});
  final int docId;

  @override
  ConsumerState<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends ConsumerState<ReaderScreen> {
  final _controller = PdfViewerController();
  late final _searcher = PdfTextSearcher(_controller)..addListener(_onSearch);
  final _query = TextEditingController();
  String? _path;
  String? _error;
  String _title = '';
  int? _page;
  bool _searching = false;

  static const _options = PdfOptions(size: PdfPageSize.fit, margin: PdfMargin.none, searchable: true);

  @override
  void initState() {
    super.initState();
    _build();
  }

  @override
  void dispose() {
    _searcher
      ..removeListener(_onSearch)
      ..dispose();
    _query.dispose();
    super.dispose();
  }

  void _onSearch() {
    if (mounted) setState(() {});
  }

  /// PDF for the current state of the document, reused while nothing that
  /// affects it has changed.
  Future<void> _build() async {
    try {
      final db = ref.read(dbProvider);
      final store = ref.read(storeProvider);
      final doc = await db.documentById(widget.docId);
      final pages = await db.pagesOf(widget.docId);
      if (doc == null) throw StateError('文档不存在');
      if (pages.isEmpty) throw StateError('没有页面');
      _title = doc.title;
      final key = sha1.convert(utf8.encode(jsonEncode([
        doc.watermarkJson,
        for (final pg in pages) [pg.processedFile, pg.markupJson, pg.ocrJson],
      ]))).toString().substring(0, 16);
      final f = await TempFiles.readerFile(widget.docId, key);
      if (!await f.exists()) {
        // Older versions of this document's PDF are stale now.
        await TempFiles.forgetDocument(widget.docId);
        final bytes = await Exporter(store, watermark: Watermark.parse(doc.watermarkJson)).buildPdf(pages, options: _options);
        // Written aside and renamed: a crash mid-write must not leave a
        // truncated file that looks like a valid cache entry.
        final tmp = File('${f.path}.tmp');
        await tmp.writeAsBytes(bytes, flush: true);
        await tmp.rename(f.path);
      }
      if (mounted) setState(() => _path = f.path);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<Uint8List> _bytes() => File(_path!).readAsBytes();

  Future<void> _jump() async {
    if (!_controller.isReady) return;
    final n = _controller.pageCount;
    final v = await promptText(context, title: '跳到第几页（1–$n）', maxLength: 5);
    final page = int.tryParse(v ?? '');
    if (page == null) return;
    await _controller.goToPage(pageNumber: page.clamp(1, n));
  }

  Future<void> _thumbnails() async {
    if (!_controller.isReady) return;
    final pages = await ref.read(dbProvider).pagesOf(widget.docId);
    if (!mounted) return;
    final store = ref.read(storeProvider);
    final picked = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.6,
        child: GridView.builder(
          padding: const EdgeInsets.all(12),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, childAspectRatio: 0.7),
          itemCount: pages.length,
          itemBuilder: (_, i) => InkWell(
            onTap: () => Navigator.pop(ctx, i + 1),
            child: Column(children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: i + 1 == _page ? Theme.of(ctx).colorScheme.primary : Colors.black12, width: 2),
                  ),
                  child: Image.file(File(store.file(pages[i].thumbFile).path), fit: BoxFit.contain),
                ),
              ),
              Text('${i + 1}'),
            ]),
          ),
        ),
      ),
    );
    if (picked != null) await _controller.goToPage(pageNumber: picked);
  }

  Future<void> _print() async {
    if (_path == null) return;
    final bytes = await _bytes();
    await Printing.layoutPdf(onLayout: (_) async => bytes, name: _title);
  }

  Future<void> _share() async {
    final path = _path;
    if (path == null) return;
    final dir = await TempFiles.dir('export');
    final out = await File(path).copy(p.join(dir.path, '${Exporter.safeName(_title)}.pdf'));
    await SharePlus.instance.share(ShareParams(files: [XFile(out.path, mimeType: 'application/pdf')], subject: _title));
  }

  @override
  Widget build(BuildContext context) {
    final matches = _searcher.matches.length;
    final current = (_searcher.currentIndex ?? -1) + 1;
    return Scaffold(
      appBar: _searching
          ? AppBar(
              leading: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => setState(() {
                  _searching = false;
                  _query.clear();
                  _searcher.resetTextSearch();
                }),
              ),
              title: TextField(
                controller: _query,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(hintText: '搜索文字', border: InputBorder.none),
                onSubmitted: (v) {
                  if (v.trim().isNotEmpty) _searcher.startTextSearch(v.trim(), caseInsensitive: true);
                },
              ),
              actions: [
                if (_searcher.isSearching)
                  const Padding(padding: EdgeInsets.all(16), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
                else if (_query.text.isNotEmpty)
                  Center(child: Text(matches == 0 ? '无结果' : '$current/$matches')),
                IconButton(onPressed: matches == 0 ? null : _searcher.goToPrevMatch, icon: const Icon(Icons.keyboard_arrow_up)),
                IconButton(onPressed: matches == 0 ? null : _searcher.goToNextMatch, icon: const Icon(Icons.keyboard_arrow_down)),
              ],
            )
          : AppBar(
              title: Text(_title, overflow: TextOverflow.ellipsis),
              actions: [
                IconButton(tooltip: '搜索', onPressed: _path == null ? null : () => setState(() => _searching = true), icon: const Icon(Icons.search)),
                IconButton(tooltip: '缩略图', onPressed: _path == null ? null : _thumbnails, icon: const Icon(Icons.grid_view)),
                PopupMenuButton<String>(
                  enabled: _path != null,
                  onSelected: (v) => switch (v) {
                    'jump' => _jump(),
                    'print' => _print(),
                    _ => _share(),
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'jump', child: ListTile(leading: Icon(Icons.low_priority), title: Text('跳到页'))),
                    PopupMenuItem(value: 'print', child: ListTile(leading: Icon(Icons.print_outlined), title: Text('打印'))),
                    PopupMenuItem(value: 'share', child: ListTile(leading: Icon(Icons.ios_share), title: Text('分享 PDF'))),
                  ],
                ),
              ],
            ),
      body: _error != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('打开失败：$_error', textAlign: TextAlign.center)))
          : _path == null
              ? const Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 12),
                    Text('正在生成…'),
                  ]),
                )
              : Stack(children: [
                  PdfViewer.file(
                    _path!,
                    controller: _controller,
                    params: PdfViewerParams(
                      backgroundColor: const Color(0xFF424242),
                      margin: 8,
                      pagePaintCallbacks: [_searcher.pageTextMatchPaintCallback],
                      onPageChanged: (n) => setState(() => _page = n),
                    ),
                  ),
                  if (_page != null && _controller.isReady)
                    Positioned(
                      right: 12,
                      bottom: 16,
                      child: GestureDetector(
                        onTap: _jump,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(16)),
                          child: Text('$_page / ${_controller.pageCount}', style: const TextStyle(color: Colors.white)),
                        ),
                      ),
                    ),
                ]),
    );
  }
}
