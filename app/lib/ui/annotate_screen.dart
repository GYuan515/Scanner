import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_state.dart';
import '../data/db.dart';
import '../data/page_store.dart';
import '../markup/compositor.dart';
import '../markup/markup.dart';
import '../markup/markup_painter.dart';
import '../ocr/ocr_result.dart';
import 'image_size.dart';
import 'library_actions.dart';
import 'quad_overlay.dart';
import 'signature_screens.dart';

enum _Tool {
  select('选择', Icons.pan_tool_alt_outlined),
  pen('画笔', Icons.brush_outlined),
  highlight('高亮', Icons.highlight),
  underline('下划线', Icons.format_underline),
  strike('删除线', Icons.format_strikethrough),
  text('文字', Icons.title),
  note('便签', Icons.sticky_note_2_outlined),
  signature('签名', Icons.draw_outlined),
  eraser('橡皮', Icons.auto_fix_normal_outlined);

  const _Tool(this.label, this.icon);
  final String label;
  final IconData icon;
}

const _inkColors = [Color(0xFFE53935), Color(0xFF1E88E5), Color(0xFF111111), Color(0xFF43A047)];
const _highlightColors = [Color(0x80FFEB3B), Color(0x8066BB6A), Color(0x80F48FB1), Color(0x8064B5F6)];

/// Draws annotations on one page. Every change is saved right away; undo
/// and redo work for the whole visit.
class AnnotateScreen extends ConsumerStatefulWidget {
  const AnnotateScreen({super.key, required this.pageId});
  final int pageId;

  @override
  ConsumerState<AnnotateScreen> createState() => _AnnotateScreenState();
}

class _AnnotateScreenState extends ConsumerState<AnnotateScreen> {
  late final PageStore _store = ref.read(storeProvider);
  ScanPage? _page;
  Size? _imageSize;
  OcrResult? _ocr;

  PageMarkup _markup = PageMarkup.empty;
  final _undo = <PageMarkup>[];
  final _redo = <PageMarkup>[];

  /// Signature files placed during this visit; ones no longer used when the
  /// screen closes are deleted then (not on every edit, so undo can bring
  /// a removed signature back).
  final _added = <String>{};
  final _initialFiles = <String>{};

  var _images = <String, ui.Image>{};
  late MarkupRenderer _renderer = MarkupRenderer();

  _Tool _tool = _Tool.pen;
  Color _ink = _inkColors.first;
  Color _highlight = _highlightColors.first;
  double _penWidth = 6; // relative to a 1000 px wide page

  int _selected = -1;
  MarkupItem? _preview;
  Offset? _dragStart;

  /// Where the finger went down (view pixels). Drag callbacks only start
  /// after the touch slop, so without this every stroke and highlight
  /// would lose its first few millimetres.
  Offset? _downAt;

  // Select-tool gesture state.
  MarkupItem? _gestureItem;
  Offset _gestureFocal = Offset.zero;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    final unused = {..._added}..removeAll(_markup.imageFiles);
    // Files of the original markup that the user removed during the visit.
    final removed = {..._initialFiles}..removeAll(_markup.imageFiles);
    if (unused.isNotEmpty || removed.isNotEmpty) {
      final files = [...unused, ...removed];
      unawaited(_lastWrite.then((_) => _deleteFiles(files)));
    }
    disposeImages(_images);
    super.dispose();
  }

  Future<void> _deleteFiles(List<String> names) async {
    for (final n in names) {
      try {
        await _store.file(n).delete();
      } on FileSystemException {
        // Already gone.
      }
    }
  }

  Future<void> _load() async {
    final pg = await ref.read(dbProvider).pageById(widget.pageId);
    if (pg == null || !mounted) return;
    final size = await imageSizeOf(_store.file(pg.processedFile).path);
    final markup = PageMarkup.parse(pg.markupJson);
    _initialFiles.addAll(markup.imageFiles);
    await _refreshImages(markup);
    // Images loaded after dispose are released by nobody else.
    if (!mounted) {
      disposeImages(_images);
      _images = {};
      return;
    }
    setState(() {
      _page = pg;
      _imageSize = size;
      _markup = markup;
      _ocr = pg.ocrJson == null ? null : OcrResult.fromJsonString(pg.ocrJson!);
    });
  }

  Future<void> _refreshImages(PageMarkup m) async {
    final missing = m.imageFiles.where((f) => !_images.containsKey(f)).toList();
    if (missing.isEmpty) return;
    final loaded = await loadMarkupImages(_store, missing);
    _images = {..._images, ...loaded};
    _renderer = MarkupRenderer(images: _images);
  }

  double get _unit => (_imageSize?.width ?? 1000) / 1000;

  /// Last database write; file cleanup in dispose waits for it so the
  /// database never points at a file that was just deleted.
  Future<void> _lastWrite = Future.value();

  Future<void> _commit(PageMarkup next, {bool record = true}) async {
    if (!mounted) return;
    if (record) {
      _undo.add(_markup);
      _redo.clear();
    }
    setState(() => _markup = next);
    final db = ref.read(dbProvider);
    final page = _page;
    final write = _lastWrite.then((_) async {
      await db.setMarkup(widget.pageId, next.toJsonString());
      if (page != null) await db.touch(page.documentId);
    });
    _lastWrite = write.catchError((Object _) {});
    await write;
  }

  void _undoStep() {
    if (_undo.isEmpty) return;
    _redo.add(_markup);
    _selected = -1;
    _commit(_undo.removeLast(), record: false);
  }

  void _redoStep() {
    if (_redo.isEmpty) return;
    _undo.add(_markup);
    _selected = -1;
    _commit(_redo.removeLast(), record: false);
  }

  // --------------------------------------------------------------- gestures

  void _onTap(Offset p) async {
    switch (_tool) {
      case _Tool.select:
        final i = _markup.hitTest(p, 16 * _unit);
        setState(() => _selected = i);
      case _Tool.eraser:
        final i = _markup.hitTest(p, 16 * _unit);
        if (i >= 0) await _commit(_markup.removeAt(i));
      case _Tool.text:
        final text = await _askText('添加文字');
        if (text == null) return;
        final size = 36 * _unit;
        final s = MarkupRenderer.measureText(text, size);
        await _commit(
          _markup.add(
            MarkupItem(
              kind: MarkupKind.text,
              color: _ink.toARGB32(),
              width: size,
              text: text,
              rect: Rect.fromLTWH(p.dx, p.dy - s.height / 2, s.width + 2, s.height),
            ),
          ),
        );
        setState(() {
          _tool = _Tool.select;
          _selected = _markup.items.length - 1;
        });
      case _Tool.note:
        final text = await _askText('便签内容');
        if (text == null) return;
        final side = 44 * _unit;
        await _commit(
          _markup.add(MarkupItem(kind: MarkupKind.note, text: text, rect: Rect.fromLTWH(p.dx, p.dy, side, side))),
        );
      default:
        break;
    }
  }

  Future<String?> _askText(String title, [String initial = '']) =>
      promptText(context, title: title, initial: initial, maxLength: 500);

  Future<void> _onDoubleTap(Offset p) async {
    final i = _markup.hitTest(p, 16 * _unit);
    if (i < 0) return;
    final it = _markup.items[i];
    if (it.kind != MarkupKind.text && it.kind != MarkupKind.note) return;
    final text = await _askText(it.kind == MarkupKind.text ? '修改文字' : '便签内容', it.text);
    if (text == null) return;
    var next = it.copyWith(text: text);
    if (it.kind == MarkupKind.text) {
      final s = MarkupRenderer.measureText(text, it.width);
      next = next.copyWith(rect: Rect.fromLTWH(it.rect.left, it.rect.top, s.width + 2, s.height));
    }
    await _commit(_markup.replaceAt(i, next));
  }

  void _onScaleStart(ScaleStartDetails d, ImageMapping m) {
    final p = d.pointerCount <= 1 && _downAt != null ? m.toImage(_downAt!) : m.toImage(d.localFocalPoint);
    _dragStart = p;
    switch (_tool) {
      case _Tool.pen:
        _preview = MarkupItem(kind: MarkupKind.ink, color: _ink.toARGB32(), width: _penWidth * _unit, points: [p]);
      case _Tool.highlight:
      case _Tool.underline:
      case _Tool.strike:
        _preview = null;
      case _Tool.select:
        var i = _selected;
        if (i < 0 || !_markup.items[i].hit(p, 24 * _unit)) i = _markup.hitTest(p, 16 * _unit);
        _selected = i;
        _gestureItem = i >= 0 ? _markup.items[i] : null;
        _gestureFocal = p;
      case _Tool.eraser:
        _erase(p);
      default:
        break;
    }
    setState(() {});
  }

  void _onScaleUpdate(ScaleUpdateDetails d, ImageMapping m) {
    final p = m.toImage(d.localFocalPoint);
    switch (_tool) {
      case _Tool.pen:
        final pv = _preview;
        if (pv == null) return;
        if ((pv.points.last - p).distance < 2 * _unit) return;
        setState(() => _preview = pv.copyWith(points: [...pv.points, p]));
      case _Tool.highlight:
      case _Tool.underline:
      case _Tool.strike:
        final r = Rect.fromPoints(_dragStart!, p);
        setState(() => _preview = _markItem(r));
      case _Tool.select:
        final base = _gestureItem;
        if (base == null || _selected < 0) return;
        final delta = p - _gestureFocal;
        setState(() => _markup = _markup.replaceAt(_selected, _transformed(base, delta, d.scale, d.rotation)));
      case _Tool.eraser:
        _erase(p);
      default:
        break;
    }
  }

  Future<void> _onScaleEnd(ScaleEndDetails d) async {
    switch (_tool) {
      case _Tool.pen:
        final pv = _preview;
        _preview = null;
        if (pv != null) await _commit(_markup.add(pv));
      case _Tool.highlight:
      case _Tool.underline:
      case _Tool.strike:
        final pv = _preview;
        _preview = null;
        if (pv != null && pv.rect.width > 4 * _unit) {
          var next = _markup;
          for (final it in _snapToLines(pv)) {
            next = next.add(it);
          }
          await _commit(next);
        } else {
          setState(() {});
        }
      case _Tool.select:
        final base = _gestureItem;
        _gestureItem = null;
        if (base != null && _selected >= 0) {
          // Live updates were not recorded; record the whole move as one step.
          final moved = _markup;
          _markup = _markup.replaceAt(_selected, base);
          await _commit(moved);
        }
      default:
        break;
    }
  }

  void _erase(Offset p) {
    final i = _markup.hitTest(p, 12 * _unit);
    if (i >= 0) _commit(_markup.removeAt(i));
  }

  MarkupItem _markItem(Rect r) => switch (_tool) {
    _Tool.highlight => MarkupItem(kind: MarkupKind.highlight, color: _highlight.toARGB32(), rect: r),
    _Tool.underline => MarkupItem(kind: MarkupKind.underline, color: _ink.toARGB32(), width: 3 * _unit, rect: r),
    _ => MarkupItem(kind: MarkupKind.strike, color: _ink.toARGB32(), width: 3 * _unit, rect: r),
  };

  /// Turns a dragged box into one mark per recognized text line it covers,
  /// clipped to the drag horizontally, so a sloppy swipe still marks the
  /// words exactly. Without recognized text the box is used as drawn.
  List<MarkupItem> _snapToLines(MarkupItem drawn) {
    final r = drawn.rect;
    final lines =
        _ocr?.lines.where((l) {
          final b = l.bounds;
          final overlap = math.min(b.bottom, r.bottom) - math.max(b.top, r.top);
          return overlap > b.height * 0.4 && b.right > r.left && b.left < r.right;
        }).toList() ??
        const <OcrLine>[];
    if (lines.isEmpty) {
      // Underline / strike drawn as a stroke: a thin box at the finger.
      if (drawn.kind != MarkupKind.highlight && r.height < 12 * _unit) {
        return [drawn.copyWith(rect: Rect.fromLTRB(r.left, r.center.dy - 8 * _unit, r.right, r.center.dy + 8 * _unit))];
      }
      return [drawn];
    }
    return [
      for (final l in lines)
        drawn.copyWith(
          rect: Rect.fromLTRB(
            math.max(l.bounds.left, r.left),
            l.bounds.top,
            math.min(l.bounds.right, r.right),
            l.bounds.bottom,
          ),
          width: drawn.kind == MarkupKind.highlight ? drawn.width : math.max(2 * _unit, l.height * 0.08),
        ),
    ];
  }

  MarkupItem _transformed(MarkupItem it, Offset delta, double scale, double rotation) {
    if (it.kind == MarkupKind.ink) {
      return it.copyWith(points: [for (final p in it.points) p + delta]);
    }
    final c = it.rect.center + delta;
    final resizable = it.kind == MarkupKind.image || it.kind == MarkupKind.text;
    final s = resizable ? scale.clamp(0.1, 10.0) : 1.0;
    final r = Rect.fromCenter(center: c, width: it.rect.width * s, height: it.rect.height * s);
    return it.copyWith(
      rect: r,
      angle: resizable ? it.angle + rotation : it.angle,
      width: it.kind == MarkupKind.text ? it.width * s : it.width,
    );
  }

  Future<void> _addSignature() async {
    final png = await pickSignature(context);
    if (png == null || !mounted) return;
    final name = await _store.addMarkupImage(png);
    final codec = await ui.instantiateImageCodec(png);
    final img = (await codec.getNextFrame()).image;
    codec.dispose();
    if (!mounted) {
      // Left the editor meanwhile: nothing will reference the file.
      img.dispose();
      await _deleteFiles([name]);
      return;
    }
    _added.add(name);
    final size = _imageSize!;
    final w = size.width * 0.35, h = w * img.height / img.width;
    _images = {..._images, name: img};
    _renderer = MarkupRenderer(images: _images);
    await _commit(
      _markup.add(
        MarkupItem(
          kind: MarkupKind.image,
          image: name,
          rect: Rect.fromCenter(center: Offset(size.width / 2, size.height * 0.75), width: w, height: h),
        ),
      ),
    );
    setState(() {
      _tool = _Tool.select;
      _selected = _markup.items.length - 1;
    });
    if (mounted) toast(context, '拖动摆放，双指缩放和旋转');
  }

  void _deleteSelected() {
    if (_selected < 0) return;
    final i = _selected;
    _selected = -1;
    _commit(_markup.removeAt(i));
  }

  // -------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final pg = _page, size = _imageSize;
    return Scaffold(
      backgroundColor: const Color(0xFF303030),
      appBar: AppBar(
        title: const Text('标注'),
        actions: [
          IconButton(tooltip: '撤销', onPressed: _undo.isEmpty ? null : _undoStep, icon: const Icon(Icons.undo)),
          IconButton(tooltip: '重做', onPressed: _redo.isEmpty ? null : _redoStep, icon: const Icon(Icons.redo)),
          if (_selected >= 0)
            IconButton(tooltip: '删除所选', onPressed: _deleteSelected, icon: const Icon(Icons.delete_outline)),
        ],
      ),
      body: pg == null || size == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: LayoutBuilder(
                      builder: (context, box) {
                        final m = ImageMapping(size, Size(box.maxWidth, box.maxHeight));
                        return Listener(
                          onPointerDown: (e) => _downAt = e.localPosition,
                          child: GestureDetector(
                            onTapUp: (d) => _onTap(m.toImage(d.localPosition)),
                            onDoubleTapDown: _tool == _Tool.select
                                ? (d) => _onDoubleTap(m.toImage(d.localPosition))
                                : null,
                            onDoubleTap: _tool == _Tool.select ? () {} : null,
                            onScaleStart: (d) => _onScaleStart(d, m),
                            onScaleUpdate: (d) => _onScaleUpdate(d, m),
                            onScaleEnd: _onScaleEnd,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                Image.file(File(_store.file(pg.processedFile).path), fit: BoxFit.contain),
                                CustomPaint(
                                  painter: MarkupOverlayPainter(
                                    renderer: _renderer,
                                    imageSize: size,
                                    markup: _markup,
                                    selected: _tool == _Tool.select ? _selected : -1,
                                    preview: _preview,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                _toolbar(),
              ],
            ),
    );
  }

  Widget _toolbar() {
    final scheme = Theme.of(context).colorScheme;
    final colors = _tool == _Tool.highlight ? _highlightColors : _inkColors;
    final current = _tool == _Tool.highlight ? _highlight : _ink;
    final showColors = {_Tool.pen, _Tool.highlight, _Tool.underline, _Tool.strike, _Tool.text}.contains(_tool);
    return Material(
      color: scheme.surface,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showColors)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Row(
                  children: [
                    for (final c in colors)
                      Padding(
                        padding: const EdgeInsets.only(right: 10),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => setState(() => _tool == _Tool.highlight ? _highlight = c : _ink = c),
                          child: CircleAvatar(
                            radius: 14,
                            backgroundColor: c.withValues(alpha: 1),
                            child: c == current ? const Icon(Icons.check, size: 16, color: Colors.white) : null,
                          ),
                        ),
                      ),
                    if (_tool == _Tool.pen) ...[
                      const SizedBox(width: 4),
                      const Icon(Icons.line_weight, size: 18),
                      Expanded(
                        child: Slider(
                          value: _penWidth,
                          min: 2,
                          max: 20,
                          onChanged: (v) => setState(() => _penWidth = v),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Row(
                children: [
                  for (final t in _Tool.values)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: TextButton(
                        style: TextButton.styleFrom(
                          foregroundColor: t == _tool ? scheme.primary : scheme.onSurfaceVariant,
                          backgroundColor: t == _tool ? scheme.primaryContainer : null,
                          minimumSize: const Size(56, 52),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                        onPressed: () {
                          if (t == _Tool.signature) {
                            _addSignature();
                            return;
                          }
                          setState(() {
                            _tool = t;
                            if (t != _Tool.select) _selected = -1;
                          });
                        },
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(t.icon),
                            const SizedBox(height: 2),
                            Text(t.label, style: const TextStyle(fontSize: 12)),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
