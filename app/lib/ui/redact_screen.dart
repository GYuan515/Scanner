import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_state.dart';
import '../data/db.dart';
import '../markup/redact.dart';
import '../ocr/ocr_result.dart';
import 'image_size.dart';
import 'library_actions.dart';
import 'quad_overlay.dart';

/// Marks areas to black out, page by page, by hand or by searching the
/// recognized text, then removes them for good.
class RedactScreen extends ConsumerStatefulWidget {
  const RedactScreen({super.key, required this.docId, this.initialIndex = 0});
  final int docId;
  final int initialIndex;

  @override
  ConsumerState<RedactScreen> createState() => _RedactScreenState();
}

class _RedactScreenState extends ConsumerState<RedactScreen> {
  late int _index = widget.initialIndex;
  final _pending = <int, List<Rect>>{}; // page id -> areas (image pixels)
  final _sizes = <String, Size>{}; // processed file -> size
  final _measuring = <String>{};
  final _keyword = TextEditingController();
  Rect? _drag;
  bool _busy = false;
  String? _status;

  @override
  void dispose() {
    _keyword.dispose();
    super.dispose();
  }

  int get _total => _pending.values.fold(0, (s, l) => s + l.length);

  Future<Size?> _sizeOf(ScanPage pg) async {
    final cached = _sizes[pg.processedFile];
    if (cached != null) return cached;
    final s = await imageSizeOf(ref.read(storeProvider).file(pg.processedFile).path);
    _sizes[pg.processedFile] = s;
    if (mounted) setState(() {});
    return s;
  }

  /// Searches every page's text; pages not read yet are read first.
  Future<void> _search(RegExp pattern, String label) async {
    setState(() {
      _busy = true;
      _status = '正在查找$label…';
    });
    try {
      final db = ref.read(dbProvider);
      final queue = ref.read(ocrQueueProvider);
      var pages = await db.pagesOf(widget.docId);
      for (final pg in pages.where((p) => p.ocrJson == null)) {
        if (mounted) setState(() => _status = '先识别文字…');
        try {
          await queue.readNow(pg);
        } catch (_) {
          // That page just cannot be searched.
        }
      }
      pages = await db.pagesOf(widget.docId);
      var found = 0;
      for (final pg in pages) {
        if (pg.ocrJson == null) continue;
        final matches = findInLines(OcrResult.fromJsonString(pg.ocrJson!).lines, pattern);
        if (matches.isEmpty) continue;
        final list = _pending.putIfAbsent(pg.id, () => []);
        for (final m in matches) {
          if (!list.contains(m.area)) {
            list.add(m.area);
            found++;
          }
        }
      }
      if (mounted) toast(context, found == 0 ? '没有找到$label' : '找到 $found 处$label，已标记');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = null;
        });
      }
    }
  }

  Future<void> _apply(List<ScanPage> pages) async {
    final n = _total;
    if (n == 0) return;
    final ok = await confirm(context, title: '涂黑 $n 处？', message: '涂黑的内容会从照片和页面里彻底删除，不能撤销。这些页的识别文字会重新识别。', ok: '涂黑');
    if (!ok || !mounted) return;
    setState(() {
      _busy = true;
      _status = '正在涂黑…';
    });
    // Read before the awaits: ref is unusable once the screen is gone.
    final store = ref.read(storeProvider);
    final db = ref.read(dbProvider);
    final queue = ref.read(ocrQueueProvider);
    final done = <int>[];
    try {
      for (final stale in pages) {
        final areas = _pending[stale.id];
        if (areas == null || areas.isEmpty) continue;
        // The stream's copy may be outdated (e.g. OCR finished meanwhile).
        final pg = await db.pageById(stale.id);
        if (pg == null) continue;
        await store.redact(pg, areas);
        done.add(pg.id);
      }
      if (mounted) {
        toast(context, '已涂黑 $n 处');
        Navigator.pop(context);
      }
    } catch (e) {
      // Pages already redacted keep the change; drop them from the list.
      for (final id in done) {
        _pending.remove(id);
      }
      if (mounted) toast(context, '涂黑失败：$e');
    } finally {
      // Re-read the text of every page that was changed, also on failure.
      queue.request(done);
      if (mounted) {
        setState(() {
          _busy = false;
          _status = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final pages = ref.watch(pagesProvider(widget.docId)).value ?? const <ScanPage>[];
    if (pages.isEmpty) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final i = _index.clamp(0, pages.length - 1);
    final pg = pages[i];
    final size = _sizes[pg.processedFile];
    if (size == null && _measuring.add(pg.processedFile)) {
      _sizeOf(pg).catchError((Object e) {
        if (mounted) setState(() => _status = '图片读取失败：$e');
        return null;
      });
    }
    final areas = _pending[pg.id] ?? const <Rect>[];
    final ocr = pg.ocrJson == null ? null : OcrResult.fromJsonString(pg.ocrJson!);

    // No leaving halfway through a redaction.
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('脱敏'),
          bottom: _busy
              ? const PreferredSize(preferredSize: Size.fromHeight(4), child: LinearProgressIndicator())
              : null,
          actions: [
            TextButton(
              onPressed: _busy || _total == 0 ? null : () => _apply(pages),
              child: Text(_total == 0 ? '涂黑' : '涂黑（$_total）'),
            ),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _keyword,
                      textInputAction: TextInputAction.search,
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: '查找关键字，全部页',
                        prefixIcon: Icon(Icons.search),
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (v) {
                        if (v.trim().isNotEmpty) {
                          _search(RegExp(RegExp.escape(v.trim()), caseSensitive: false), '“${v.trim()}”');
                        }
                      },
                    ),
                  ),
                ],
              ),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  for (final p in RedactPreset.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ActionChip(
                        avatar: const Icon(Icons.manage_search, size: 18),
                        label: Text(p.label),
                        onPressed: _busy ? null : () => _search(p.regex, p.label),
                      ),
                    ),
                ],
              ),
            ),
            if (_status != null) Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(_status!)),
            Expanded(
              child: Container(
                color: Colors.black,
                padding: const EdgeInsets.all(8),
                child: size == null
                    ? const Center(child: CircularProgressIndicator())
                    : LayoutBuilder(
                        builder: (context, box) {
                          final m = ImageMapping(size, Size(box.maxWidth, box.maxHeight));
                          return GestureDetector(
                            onTapUp: (d) {
                              final p = m.toImage(d.localPosition);
                              final hit = areas.lastIndexWhere((r) => r.contains(p));
                              if (hit >= 0) setState(() => _pending[pg.id]!.removeAt(hit));
                            },
                            onPanStart: (d) =>
                                setState(() => _drag = Rect.fromPoints(d.localPosition, d.localPosition)),
                            onPanUpdate: (d) =>
                                setState(() => _drag = Rect.fromPoints(_drag!.topLeft, d.localPosition)),
                            onPanEnd: (_) {
                              final r = _drag!;
                              setState(() => _drag = null);
                              if (r.width < 8 || r.height < 8) return;
                              final img = Rect.fromPoints(
                                m.toImage(r.topLeft),
                                m.toImage(r.bottomRight),
                              ).intersect(Offset.zero & size);
                              // Dragged outside the page: intersect gives an empty / inverted rect.
                              if (img.width < 2 || img.height < 2) return;
                              setState(() => _pending.putIfAbsent(pg.id, () => []).add(img));
                            },
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                Image.file(
                                  File(ref.read(storeProvider).file(pg.processedFile).path),
                                  fit: BoxFit.contain,
                                ),
                                CustomPaint(painter: _RedactPainter(m, areas, ocr, _drag)),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: i > 0 ? () => setState(() => _index = i - 1) : null,
                      icon: const Icon(Icons.chevron_left),
                    ),
                    Expanded(
                      child: Text(
                        '第 ${i + 1} / ${pages.length} 页 · 本页 ${areas.length} 处\n拖动框选要涂黑的地方，点红框取消',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    IconButton(
                      onPressed: i < pages.length - 1 ? () => setState(() => _index = i + 1) : null,
                      icon: const Icon(Icons.chevron_right),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RedactPainter extends CustomPainter {
  _RedactPainter(this.m, this.areas, this.ocr, this.drag);
  final ImageMapping m;
  final List<Rect> areas;
  final OcrResult? ocr;
  final Rect? drag;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = const Color(0x5590CAF9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final l in ocr?.lines ?? const <OcrLine>[]) {
      canvas.drawPath(Path()..addPolygon(l.box.map(m.toView).toList(), true), line);
    }
    final fill = Paint()..color = const Color(0xCC000000);
    final edge = Paint()
      ..color = Colors.redAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (final r in areas) {
      final v = Rect.fromPoints(m.toView(r.topLeft), m.toView(r.bottomRight));
      canvas
        ..drawRect(v, fill)
        ..drawRect(v, edge);
    }
    final d = drag;
    if (d != null) {
      canvas
        ..drawRect(d, Paint()..color = const Color(0x88000000))
        ..drawRect(d, edge);
    }
  }

  @override
  bool shouldRepaint(_RedactPainter old) => true;
}
