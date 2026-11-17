import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../markup/markup_painter.dart';
import '../markup/signature_extract.dart';
import '../scan/background.dart';
import 'library_actions.dart';
import 'quad_overlay.dart';

/// Saved signatures and stamps (transparent PNGs), newest first.
class SignatureLibrary {
  static Future<Directory> _dir() async {
    final d = Directory(p.join((await getApplicationSupportDirectory()).path, 'signatures'));
    await d.create(recursive: true);
    return d;
  }

  static Future<List<File>> list() async {
    final files = (await _dir()).listSync().whereType<File>().where((f) => f.path.endsWith('.png')).toList();
    files.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    return files;
  }

  static Future<File> save(Uint8List png) async {
    final f = File(p.join((await _dir()).path, 'sig_${DateTime.now().millisecondsSinceEpoch}.png'));
    await f.writeAsBytes(png, flush: true);
    return f;
  }
}

/// Lets the user choose a saved signature, draw a new one, or lift one off
/// a photo. Returns the PNG bytes, or null.
Future<Uint8List?> pickSignature(BuildContext context) => showModalBottomSheet<Uint8List>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _SignatureSheet(),
    );

class _SignatureSheet extends StatefulWidget {
  const _SignatureSheet();

  @override
  State<_SignatureSheet> createState() => _SignatureSheetState();
}

class _SignatureSheetState extends State<_SignatureSheet> {
  List<File>? _files;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final f = await SignatureLibrary.list();
    if (mounted) setState(() => _files = f);
  }

  Future<void> _use(Uint8List? png) async {
    if (png == null || !mounted) return;
    await SignatureLibrary.save(png);
    if (mounted) Navigator.pop(context, png);
  }

  Future<void> _fromPhoto(ImageSource source) async {
    final x = await ImagePicker().pickImage(source: source);
    if (x == null || !mounted) return;
    // Normalise orientation/size the same way scans are prepared.
    final prepared = await prepareInBackground(await x.readAsBytes());
    if (!mounted) return;
    final png = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(builder: (_) => ExtractSignatureScreen(photo: prepared.bytes, width: prepared.width, height: prepared.height)),
    );
    await _use(png);
  }

  Future<void> _delete(File f) async {
    if (!await confirm(context, title: '删除这个签名？', ok: '删除')) return;
    await f.delete();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final files = _files;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('签名和印章', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.tonalIcon(
              onPressed: () async => _use(await Navigator.of(context)
                  .push<Uint8List>(MaterialPageRoute(builder: (_) => const SignaturePadScreen()))),
              icon: const Icon(Icons.draw_outlined),
              label: const Text('手写签名'),
            ),
            FilledButton.tonalIcon(
              onPressed: () => _fromPhoto(ImageSource.camera),
              icon: const Icon(Icons.photo_camera_outlined),
              label: const Text('拍照提取'),
            ),
            FilledButton.tonalIcon(
              onPressed: () => _fromPhoto(ImageSource.gallery),
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('从相册提取'),
            ),
          ]),
          const SizedBox(height: 16),
          if (files == null)
            const Center(child: CircularProgressIndicator())
          else if (files.isEmpty)
            const Padding(padding: EdgeInsets.all(24), child: Text('还没有保存的签名', textAlign: TextAlign.center))
          else
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.45),
              child: GridView.builder(
                shrinkWrap: true,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, childAspectRatio: 2.2),
                itemCount: files.length,
                itemBuilder: (_, i) => Card(
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () async {
                      final png = await files[i].readAsBytes();
                      if (context.mounted) Navigator.pop(context, png);
                    },
                    onLongPress: () => _delete(files[i]),
                    child: Padding(padding: const EdgeInsets.all(8), child: Image.file(files[i], fit: BoxFit.contain)),
                  ),
                ),
              ),
            ),
          if (files != null && files.isNotEmpty)
            const Padding(padding: EdgeInsets.only(top: 8), child: Text('长按可以删除', textAlign: TextAlign.center)),
        ]),
      ),
    );
  }
}

/// Finger-drawn signature on a blank pad; returns a trimmed transparent PNG.
class SignaturePadScreen extends StatefulWidget {
  const SignaturePadScreen({super.key});

  @override
  State<SignaturePadScreen> createState() => _SignaturePadScreenState();
}

class _SignaturePadScreenState extends State<SignaturePadScreen> {
  final _strokes = <List<Offset>>[];
  Color _color = const Color(0xFF111111);
  double _width = 5;

  static const _colors = [Color(0xFF111111), Color(0xFF1A3FB0), Color(0xFFC62828)];

  Future<void> _done() async {
    final pts = _strokes.expand((s) => s);
    if (pts.isEmpty) return;
    var bounds = Rect.fromPoints(pts.first, pts.first);
    for (final p in pts) {
      bounds = bounds.expandToInclude(Rect.fromCenter(center: p, width: _width, height: _width));
    }
    // Render at 3x for a crisp result on a scanned page.
    const scale = 3.0;
    final r = bounds.inflate(_width * 2);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)
      ..scale(scale)
      ..translate(-r.left, -r.top);
    final paint = Paint()
      ..color = _color
      ..strokeWidth = _width
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (final s in _strokes) {
      if (s.length == 1) {
        canvas.drawCircle(s.first, _width / 2, Paint()..color = _color);
      } else {
        canvas.drawPath(MarkupRenderer.smoothPath(s), paint);
      }
    }
    final img = await recorder.endRecording().toImage((r.width * scale).ceil(), (r.height * scale).ceil());
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    if (mounted) Navigator.pop(context, png!.buffer.asUint8List());
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('手写签名'),
          actions: [
            IconButton(
              tooltip: '撤销一笔',
              onPressed: _strokes.isEmpty ? null : () => setState(_strokes.removeLast),
              icon: const Icon(Icons.undo),
            ),
            IconButton(
              tooltip: '清空',
              onPressed: _strokes.isEmpty ? null : () => setState(_strokes.clear),
              icon: const Icon(Icons.delete_sweep_outlined),
            ),
            TextButton(onPressed: _strokes.isEmpty ? null : _done, child: const Text('完成')),
          ],
        ),
        body: Column(children: [
          Expanded(
            child: Container(
              margin: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: Colors.white, border: Border.all(color: Colors.black26)),
              child: ClipRect(
                child: GestureDetector(
                  onPanStart: (d) => setState(() => _strokes.add([d.localPosition])),
                  onPanUpdate: (d) => setState(() => _strokes.last.add(d.localPosition)),
                  child: CustomPaint(
                    painter: _PadPainter(_strokes, _color, _width),
                    child: const Center(child: Text('在这里签名', style: TextStyle(color: Colors.black12, fontSize: 28))),
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(children: [
                for (final c in _colors)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: InkWell(
                      onTap: () => setState(() => _color = c),
                      child: CircleAvatar(
                        radius: 16,
                        backgroundColor: c,
                        child: c == _color ? const Icon(Icons.check, size: 16, color: Colors.white) : null,
                      ),
                    ),
                  ),
                const SizedBox(width: 8),
                const Text('粗细'),
                Expanded(
                  child: Slider(value: _width, min: 2, max: 12, onChanged: (v) => setState(() => _width = v)),
                ),
              ]),
            ),
          ),
        ]),
      );
}

class _PadPainter extends CustomPainter {
  _PadPainter(this.strokes, this.color, this.width);
  final List<List<Offset>> strokes;
  final Color color;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = width
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (final s in strokes) {
      if (s.length == 1) {
        canvas.drawCircle(s.first, width / 2, Paint()..color = color);
      } else {
        canvas.drawPath(MarkupRenderer.smoothPath(s), paint);
      }
    }
  }

  // Strokes are mutated in place, so always repaint.
  @override
  bool shouldRepaint(_PadPainter old) => true;
}

/// Lift a signature or stamp off a photo: select the area, tune the ink
/// threshold, pick a colour, preview on a checkerboard.
class ExtractSignatureScreen extends StatefulWidget {
  const ExtractSignatureScreen({super.key, required this.photo, required this.width, required this.height});
  final Uint8List photo;
  final int width;
  final int height;

  @override
  State<ExtractSignatureScreen> createState() => _ExtractSignatureScreenState();
}

class _ExtractSignatureScreenState extends State<ExtractSignatureScreen> {
  Rect? _sel; // photo pixels
  Rect? _drag; // view pixels while dragging
  double _strength = 0.5;
  InkColor _color = InkColor.original;
  Uint8List? _result;
  String? _error;
  bool _busy = false;
  int _gen = 0;

  Size get _size => Size(widget.width.toDouble(), widget.height.toDouble());

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final gen = ++_gen;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final s = _sel;
      final png = await extractSignatureInBackground(
        widget.photo,
        crop: s == null ? null : (s.left.round(), s.top.round(), s.width.round(), s.height.round()),
        strength: _strength,
        color: _color,
      );
      if (mounted && gen == _gen) setState(() => _result = png);
    } on FormatException catch (e) {
      if (mounted && gen == _gen) {
        setState(() {
          _result = null;
          _error = e.message;
        });
      }
    } catch (e) {
      if (mounted && gen == _gen) {
        setState(() {
          _result = null;
          _error = '$e';
        });
      }
    } finally {
      if (mounted && gen == _gen) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('提取签名 / 印章'),
          actions: [
            TextButton(onPressed: _result == null || _busy ? null : () => Navigator.pop(context, _result), child: const Text('使用')),
          ],
        ),
        body: Column(children: [
          Expanded(
            flex: 3,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: LayoutBuilder(builder: (context, box) {
                final m = ImageMapping(_size, Size(box.maxWidth, box.maxHeight));
                final selView = _drag ?? (_sel == null ? null : Rect.fromPoints(m.toView(_sel!.topLeft), m.toView(_sel!.bottomRight)));
                return GestureDetector(
                  onPanStart: (d) => setState(() => _drag = Rect.fromPoints(d.localPosition, d.localPosition)),
                  onPanUpdate: (d) => setState(() => _drag = Rect.fromPoints(_drag!.topLeft, d.localPosition)),
                  onPanEnd: (_) {
                    final r = _drag!;
                    _drag = null;
                    if (r.width < 16 || r.height < 16) {
                      setState(() => _sel = null);
                    } else {
                      _sel = Rect.fromPoints(m.toImage(r.topLeft), m.toImage(r.bottomRight)).intersect(Offset.zero & _size);
                    }
                    _run();
                  },
                  child: Stack(fit: StackFit.expand, children: [
                    Image.memory(widget.photo, fit: BoxFit.contain, gaplessPlayback: true),
                    if (selView != null)
                      CustomPaint(painter: _SelectionPainter(selView)),
                  ]),
                );
              }),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('在照片上拖出签名或印章所在的区域；不框选就用整张照片', style: TextStyle(fontSize: 12)),
          ),
          Expanded(
            flex: 2,
            child: Container(
              margin: const EdgeInsets.all(12),
              decoration: BoxDecoration(border: Border.all(color: Colors.black12)),
              child: CustomPaint(
                painter: _CheckerPainter(),
                child: Center(
                  child: _busy && _result == null
                      ? const CircularProgressIndicator()
                      : _error != null
                          ? Padding(padding: const EdgeInsets.all(12), child: Text(_error!, textAlign: TextAlign.center))
                          : _result == null
                              ? const SizedBox()
                              : Padding(padding: const EdgeInsets.all(8), child: Image.memory(_result!, gaplessPlayback: true)),
                ),
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Column(children: [
                Row(children: [
                  const Text('笔迹浓淡'),
                  Expanded(
                    child: Slider(
                      value: _strength,
                      onChanged: (v) => setState(() => _strength = v),
                      onChangeEnd: (_) => _run(),
                    ),
                  ),
                ]),
                SegmentedButton<InkColor>(
                  segments: [for (final c in InkColor.values) ButtonSegment(value: c, label: Text(c.label))],
                  selected: {_color},
                  onSelectionChanged: (s) {
                    setState(() => _color = s.first);
                    _run();
                  },
                ),
              ]),
            ),
          ),
        ]),
      );
}

class _SelectionPainter extends CustomPainter {
  _SelectionPainter(this.r);
  final Rect r;

  @override
  void paint(Canvas canvas, Size size) {
    final outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(r);
    canvas.drawPath(outside, Paint()..color = const Color(0x88000000));
    canvas.drawRect(
      r,
      Paint()
        ..color = Colors.amber
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_SelectionPainter old) => old.r != r;
}

/// Checkerboard so transparency is visible in the preview.
class _CheckerPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const s = 12.0;
    final a = Paint()..color = const Color(0xFFEEEEEE);
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    for (var y = 0.0; y < size.height; y += s) {
      for (var x = ((y / s).floor().isOdd ? s : 0.0); x < size.width; x += 2 * s) {
        canvas.drawRect(Rect.fromLTWH(x, y, s, s), a);
      }
    }
  }

  @override
  bool shouldRepaint(_CheckerPainter old) => false;
}
