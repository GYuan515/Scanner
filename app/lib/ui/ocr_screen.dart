import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_state.dart';
import '../data/db.dart';
import '../data/exporter.dart';
import '../ocr/ocr_result.dart';
import 'library_actions.dart';
import 'quad_overlay.dart';

/// Recognized text of one page: the image with the detected boxes on top,
/// the editable text below. Tap a box to copy that line; switch to
/// selection mode to read just a dragged rectangle.
class OcrScreen extends ConsumerStatefulWidget {
  const OcrScreen({super.key, required this.pageId, this.title = '文字'});
  final int pageId;
  final String title;

  @override
  ConsumerState<OcrScreen> createState() => _OcrScreenState();
}

class _OcrScreenState extends ConsumerState<OcrScreen> {
  final _text = TextEditingController();
  // Captured up front: ref may not be used from dispose(), where the last
  // edit is saved.
  late final AppDatabase _db = ref.read(dbProvider);
  Timer? _saveTimer;
  bool _dirty = false;
  String? _loadedFor; // ocrJson the editor was filled from
  bool _reading = false;
  String? _error;
  // Image file an automatic read was started for: one attempt per image,
  // even if the database stream reports the result a frame late.
  String? _attemptedFor;
  bool _measuring = false;
  bool _selecting = false;
  Rect? _drag; // selection in view coordinates
  Size? _imageSize;

  @override
  void initState() {
    super.initState();
    _db; // resolve while ref is usable
  }

  @override
  void dispose() {
    _flush();
    _text.dispose();
    super.dispose();
  }

  void _onEdit(String _) {
    _dirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), _flush);
  }

  void _flush() {
    if (_saveTimer?.isActive ?? false) _saveTimer!.cancel();
    _saveTimer = null;
    if (!_dirty || _loadedFor == null) return;
    _dirty = false;
    // Fire and forget: also runs from dispose().
    unawaited(_db.setOcrText(widget.pageId, _text.text));
  }

  Future<void> _read(ScanPage pg, {bool again = false}) async {
    if (_reading) return;
    _attemptedFor = pg.processedFile;
    setState(() {
      _reading = true;
      _error = null;
    });
    try {
      final r = await ref.read(ocrQueueProvider).readNow(pg, replace: again);
      if (again && r != null && mounted) {
        // Show the fresh text even if the stored JSON did not change.
        _loadedFor = r.toJsonString();
        _dirty = false;
        _text.text = r.text;
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  /// Image size for region selection before any OCR result exists.
  Future<void> _measure(String path) async {
    if (_measuring) return;
    _measuring = true;
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? desc;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(await File(path).readAsBytes());
      desc = await ui.ImageDescriptor.encoded(buffer);
      final size = Size(desc.width.toDouble(), desc.height.toDouble());
      if (mounted) setState(() => _imageSize = size);
    } catch (_) {
      // Leave the image area empty; the page is probably being re-rendered.
    } finally {
      desc?.dispose();
      buffer?.dispose();
    }
  }

  void _retry() {
    // A failed engine start is cached by the provider; start it afresh.
    if (ref.read(ocrEngineProvider).hasError) ref.invalidate(ocrEngineProvider);
    setState(() {
      _error = null;
      _attemptedFor = null;
    });
  }

  Future<void> _readRegion(String path, Rect region) async {
    setState(() => _reading = true);
    String? text;
    try {
      final engine = await ref.read(ocrEngineProvider.future);
      text = (await engine.recognizeFile(path, region: region)).text;
    } catch (e) {
      if (mounted) toast(context, '识别失败：$e');
    } finally {
      if (mounted) setState(() => _reading = false);
    }
    if (text != null && mounted) await _showSnippet(text);
  }

  Future<void> _showSnippet(String text) => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (ctx) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.4),
                child: SingleChildScrollView(
                  child: SelectableText(text.isEmpty ? '没有识别到文字' : text, style: Theme.of(ctx).textTheme.bodyLarge),
                ),
              ),
              const SizedBox(height: 12),
              if (text.isNotEmpty)
                FilledButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: text));
                    if (ctx.mounted) Navigator.pop(ctx);
                    if (mounted) toast(context, '已复制');
                  },
                  icon: const Icon(Icons.copy),
                  label: const Text('复制'),
                ),
            ]),
          ),
        ),
      );

  Future<void> _copy(String text, [String msg = '已复制']) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) toast(context, msg);
  }

  @override
  Widget build(BuildContext context) {
    final pg = ref.watch(pageProvider(widget.pageId)).value;
    if (pg == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final path = ref.read(storeProvider).file(pg.processedFile).path;
    final ocr = pg.ocrJson == null ? null : OcrResult.fromJsonString(pg.ocrJson!);

    // Fill the editor when a (new) result arrives, but never overwrite
    // what the user is typing for the same result.
    if (pg.ocrJson != null && pg.ocrJson != _loadedFor) {
      _loadedFor = pg.ocrJson;
      _dirty = false;
      _text.text = pg.ocrText ?? '';
    }
    if (pg.ocrJson == null && !_reading && _error == null && _attemptedFor != pg.processedFile) {
      _attemptedFor = pg.processedFile; // schedule once
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _read(pg);
      });
    }
    if (_imageSize == null && ocr == null) unawaited(_measure(path));
    final imageSize = ocr != null ? Size(ocr.width.toDouble(), ocr.height.toDouble()) : _imageSize;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        bottom: _reading ? const PreferredSize(preferredSize: Size.fromHeight(4), child: LinearProgressIndicator()) : null,
        actions: [
          IconButton(
            tooltip: '框选识别',
            isSelected: _selecting,
            icon: const Icon(Icons.highlight_alt),
            onPressed: () => setState(() {
              _selecting = !_selecting;
              _drag = null;
            }),
          ),
          IconButton(
            tooltip: '复制全部',
            icon: const Icon(Icons.copy_all),
            onPressed: _text.text.isEmpty ? null : () => _copy(_text.text, '已复制全部文字'),
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              switch (v) {
                case 'txt':
                  _flush();
                  final store = ref.read(storeProvider);
                  final fresh = await _db.pageById(pg.id);
                  if (fresh != null) await Exporter(store).shareText(widget.title, [fresh]);
                case 'again':
                  await _read(pg, again: true);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'txt', child: ListTile(leading: Icon(Icons.description_outlined), title: Text('导出 TXT'))),
              PopupMenuItem(value: 'again', child: ListTile(leading: Icon(Icons.refresh), title: Text('重新识别'))),
            ],
          ),
        ],
      ),
      body: Column(children: [
        Expanded(
          flex: 5,
          child: ColoredBox(
            color: Colors.black,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: imageSize == null ? const SizedBox.expand() : _image(path, imageSize, ocr),
            ),
          ),
        ),
        if (_selecting)
          Material(
            color: Theme.of(context).colorScheme.secondaryContainer,
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 6, horizontal: 16),
              child: Row(children: [Icon(Icons.info_outline, size: 18), SizedBox(width: 8), Text('在图片上拖出一个框，只识别框里的文字')]),
            ),
          ),
        Expanded(flex: 4, child: _editor(ocr)),
      ]),
    );
  }

  Widget _editor(OcrResult? ocr) {
    if (_error != null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('识别失败：$_error', textAlign: TextAlign.center),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: _retry, child: const Text('重试')),
        ]),
      );
    }
    if (ocr == null) return const Center(child: Text('正在识别文字…'));
    if (ocr.isEmpty && _text.text.isEmpty) return const Center(child: Text('这一页没有识别到文字'));
    return TextField(
      controller: _text,
      onChanged: _onEdit,
      maxLines: null,
      expands: true,
      textAlignVertical: TextAlignVertical.top,
      decoration: const InputDecoration(
        border: InputBorder.none,
        contentPadding: EdgeInsets.all(16),
        hintText: '识别结果可以直接修改',
      ),
    );
  }

  Widget _image(String path, Size imageSize, OcrResult? ocr) => LayoutBuilder(builder: (context, box) {
        final m = ImageMapping(imageSize, Size(box.maxWidth, box.maxHeight));
        return GestureDetector(
          onTapUp: _selecting || ocr == null
              ? null
              : (d) {
                  final p = m.toImage(d.localPosition);
                  for (final l in ocr.lines) {
                    if (l.bounds.contains(p)) {
                      _copy(l.text, '已复制：${l.text}');
                      return;
                    }
                  }
                },
          onPanStart: _selecting ? (d) => setState(() => _drag = Rect.fromPoints(d.localPosition, d.localPosition)) : null,
          onPanUpdate: _selecting && _drag != null
              ? (d) => setState(() => _drag = Rect.fromPoints(_drag!.topLeft, d.localPosition))
              : null,
          onPanEnd: _selecting
              ? (_) {
                  final r = _drag;
                  setState(() => _drag = null);
                  if (r == null || r.width < 12 || r.height < 12) return;
                  final img = Rect.fromPoints(m.toImage(r.topLeft), m.toImage(r.bottomRight))
                      .intersect(Offset.zero & imageSize);
                  if (img.width >= 4 && img.height >= 4) _readRegion(path, img);
                }
              : null,
          child: Stack(fit: StackFit.expand, children: [
            Image.file(File(path), fit: BoxFit.contain, key: ValueKey(path)),
            CustomPaint(painter: _BoxPainter(ocr, m, _selecting ? _drag : null, Theme.of(context).colorScheme.primary)),
          ]),
        );
      });
}

class _BoxPainter extends CustomPainter {
  _BoxPainter(this.ocr, this.m, this.drag, this.color);
  final OcrResult? ocr;
  final ImageMapping m;
  final Rect? drag;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..color = color.withValues(alpha: 0.16);
    final stroke = Paint()
      ..color = color.withValues(alpha: 0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final l in ocr?.lines ?? const <OcrLine>[]) {
      final path = Path()..addPolygon(l.box.map(m.toView).toList(), true);
      canvas
        ..drawPath(path, fill)
        ..drawPath(path, stroke);
    }
    final d = drag;
    if (d != null) {
      canvas
        ..drawRect(d, Paint()..color = Colors.amber.withValues(alpha: 0.25))
        ..drawRect(
          d,
          Paint()
            ..color = Colors.amber
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
    }
  }

  @override
  bool shouldRepaint(_BoxPainter old) => old.ocr != ocr || old.drag != drag || old.m.scale != m.scale;
}
