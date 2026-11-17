import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_state.dart';
import '../data/db.dart';
import '../data/page_store.dart';
import '../scan/image_ops.dart';
import '../scan/quad.dart';
import '../scan/codes.dart';
import 'camera_screen.dart';
import 'annotate_screen.dart';
import 'code_sheet.dart';
import 'crop_screen.dart';
import 'marked_page.dart';
import 'ocr_screen.dart';
import 'redact_screen.dart';

/// Full-screen viewer for a saved document's pages, with per-page edits
/// (crop, filter, rotate, delete). Edits re-render from the original photo.
class PageScreen extends ConsumerStatefulWidget {
  const PageScreen({super.key, required this.docId, required this.initialIndex});
  final int docId;
  final int initialIndex;

  @override
  ConsumerState<PageScreen> createState() => _PageScreenState();
}

class _PageScreenState extends ConsumerState<PageScreen> {
  late final PageController _ctrl = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  bool _busy = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _edit(Future<void> Function() task) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await task();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('处理失败：$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _crop(ScanPage pg) async {
    final store = ref.read(storeProvider);
    final bytes = await store.file(pg.originalFile).readAsBytes();
    final img = await decodeImageFromList(bytes);
    final (w, h) = (img.width, img.height);
    img.dispose();
    if (!mounted) return;
    final q = await Navigator.of(context).push<Quad>(MaterialPageRoute(
      builder: (_) => CropScreen(image: bytes, width: w, height: h, initial: PageStore.quadOf(pg)),
    ));
    if (q != null) await _edit(() => store.updatePage(pg, quad: q));
  }

  Future<void> _pickFilter(ScanPage pg) async {
    final current = PageStore.filterOf(pg);
    final f = await showModalBottomSheet<ScanFilter>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(children: [
          for (final f in ScanFilter.values)
            ListTile(
              title: Text(f.label),
              trailing: f == current ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(ctx, f),
            ),
        ]),
      ),
    );
    if (f != null && f != current) await _edit(() => ref.read(storeProvider).updatePage(pg, filter: f));
  }

  Future<void> _retake(ScanPage pg) async {
    final draft = await Navigator.of(context).push<DraftPage>(
      MaterialPageRoute(builder: (_) => const CameraScreen(retake: true)),
    );
    if (draft != null) await _edit(() => ref.read(storeProvider).replacePage(pg, draft));
  }

  Future<void> _ocr(ScanPage pg, int index) => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => OcrScreen(pageId: pg.id, title: '第 ${index + 1} 页文字')),
      );

  Future<void> _codes(ScanPage pg) async {
    final path = ref.read(storeProvider).file(pg.processedFile).path;
    List<FoundCode>? codes;
    await _edit(() async => codes = await readCodesInBackground(path));
    if (codes != null && mounted) await showCodes(context, codes!);
  }

  Future<void> _delete(ScanPage pg, int count) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这一页？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    await _edit(() => ref.read(storeProvider).deletePage(pg));
    if (count <= 1 && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final pages = ref.watch(pagesProvider(widget.docId)).value ?? const <ScanPage>[];
    final store = ref.read(storeProvider);
    if (pages.isEmpty) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final i = _index.clamp(0, pages.length - 1);
    final pg = pages[i];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('${i + 1} / ${pages.length}'),
        bottom: _busy ? const PreferredSize(preferredSize: Size.fromHeight(4), child: LinearProgressIndicator()) : null,
        actions: [
          IconButton(tooltip: '识别二维码/条码', icon: const Icon(Icons.qr_code_scanner), onPressed: _busy ? null : () => _codes(pg)),
          IconButton(
            tooltip: '脱敏（涂黑）',
            icon: const Icon(Icons.format_color_fill),
            onPressed: _busy
                ? null
                : () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => RedactScreen(docId: widget.docId, initialIndex: i)),
                    ),
          ),
          IconButton(tooltip: '删除这一页', icon: const Icon(Icons.delete_outline), onPressed: _busy ? null : () => _delete(pg, pages.length)),
        ],
      ),
      body: PageView.builder(
        controller: _ctrl,
        itemCount: pages.length,
        onPageChanged: (v) => setState(() => _index = v),
        itemBuilder: (_, k) => InteractiveViewer(
          maxScale: 5,
          // Shows markup on top; keyed by file so an edited page reloads.
          child: Center(child: MarkedPage(page: pages[k], store: store, key: ValueKey(pages[k].processedFile))),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(children: [
            _tool(Icons.crop, '裁剪', () => _crop(pg)),
            _tool(Icons.filter_b_and_w, '滤镜', () => _pickFilter(pg)),
            _tool(Icons.rotate_right, '旋转', () => _edit(() => store.updatePage(pg, rotation: (pg.rotation + 1) % 4))),
            _tool(Icons.camera_alt_outlined, '重拍', () => _retake(pg)),
            _tool(Icons.text_snippet_outlined, '文字', () => _ocr(pg, i)),
            _tool(Icons.edit_note, '标注', () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => AnnotateScreen(pageId: pg.id)),
                )),
          ]),
        ),
      ),
    );
  }

  /// Each tool takes an equal share of the row, so all of them fit on narrow
  /// phones (a fixed-width row overflowed on a 1260 px wide screen).
  Widget _tool(IconData icon, String label, VoidCallback onTap) => Expanded(
        child: TextButton(
          onPressed: _busy ? null : onTap,
          style: TextButton.styleFrom(
            foregroundColor: Colors.white,
            padding: EdgeInsets.zero,
            minimumSize: const Size(0, 52),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(fontSize: 12), maxLines: 1, overflow: TextOverflow.fade, softWrap: false),
          ]),
        ),
      );
}
