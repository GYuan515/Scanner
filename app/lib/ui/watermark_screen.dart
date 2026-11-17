import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../app_state.dart';
import '../data/db.dart';
import '../data/page_store.dart';
import '../markup/markup.dart';
import '../markup/markup_painter.dart';
import '../markup/signature_extract.dart';
import '../markup/watermark.dart';
import '../scan/background.dart';
import 'image_size.dart';
import 'library_actions.dart';

const _colors = [Color(0xFF9E9E9E), Color(0xFF212121), Color(0xFFE53935), Color(0xFF1E88E5)];

/// Edits the document's watermark with a live preview on its first page.
class WatermarkScreen extends ConsumerStatefulWidget {
  const WatermarkScreen({super.key, required this.docId});
  final int docId;

  @override
  ConsumerState<WatermarkScreen> createState() => _WatermarkScreenState();
}

class _WatermarkScreenState extends ConsumerState<WatermarkScreen> {
  late final PageStore _store = ref.read(storeProvider);
  final _text = TextEditingController();
  Document? _doc;
  ScanPage? _page;
  Size? _pageSize;
  Watermark _wm = const Watermark(text: '仅供内部使用');
  bool _useImage = false;
  ui.Image? _image; // decoded watermark image
  String? _pendingImage; // file added in this visit, not saved yet

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _text.dispose();
    _image?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final db = ref.read(dbProvider);
    final doc = await db.documentById(widget.docId);
    final pages = await db.pagesOf(widget.docId);
    if (doc == null || !mounted) return;
    final existing = Watermark.parse(doc.watermarkJson);
    Size? size;
    if (pages.isNotEmpty) size = await imageSizeOf(_store.file(pages.first.processedFile).path);
    if (existing?.image != null) await _decode(existing!.image!);
    if (!mounted) return;
    setState(() {
      _doc = doc;
      _page = pages.isEmpty ? null : pages.first;
      _pageSize = size;
      if (existing != null) {
        _wm = existing;
        _useImage = existing.image != null;
      }
      _text.text = _wm.text;
    });
  }

  Future<void> _decode(String file) async {
    final codec = await ui.instantiateImageCodec(await _store.file(file).readAsBytes());
    final img = (await codec.getNextFrame()).image;
    codec.dispose();
    if (!mounted) {
      img.dispose();
      return;
    }
    _image?.dispose();
    _image = img;
  }

  Future<void> _pickImage() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (x == null || !mounted) return;
    final Uint8List png;
    try {
      final prepared = await prepareInBackground(await x.readAsBytes());
      // A logo on white paper: drop the white so only the mark shows.
      png = await extractSignatureInBackground(prepared.bytes, strength: 0.8);
    } on FormatException catch (e) {
      if (mounted) toast(context, e.message);
      return;
    } catch (e) {
      if (mounted) toast(context, '图片处理失败：$e');
      return;
    }
    if (!mounted) return;
    final name = await _store.addWatermarkImage(png);
    if (!mounted) {
      // Closed meanwhile: the exit cleanup already ran, so clean up here.
      await _deleteQuietly(name);
      return;
    }
    if (_pendingImage != null) await _deleteQuietly(_pendingImage!);
    _pendingImage = name;
    await _decode(name);
    if (mounted) setState(() => _wm = _wm.copyWith(image: name));
  }

  Future<void> _deleteQuietly(String name) async {
    try {
      await _store.file(name).delete();
    } on FileSystemException {
      // Already gone.
    }
  }

  /// What would be saved: image mode never falls back to the text.
  Watermark get _effective => _useImage ? _wm.copyWith(text: '') : _wm.copyWith(text: _text.text, clearImage: true);

  Future<void> _save() async {
    final doc = _doc;
    if (doc == null) return;
    final w = _effective;
    if (w.isEmpty) {
      toast(context, _useImage ? '先选一张图片' : '先输入水印文字');
      return;
    }
    await _store.setWatermark(doc, w);
    // An image picked but then replaced by a text watermark is not kept.
    if (_pendingImage != null && w.image != _pendingImage) await _deleteQuietly(_pendingImage!);
    _pendingImage = null;
    if (mounted) Navigator.pop(context);
  }

  Future<void> _remove() async {
    final doc = _doc;
    if (doc == null) return;
    await _store.setWatermark(doc, null);
    if (_pendingImage != null) await _deleteQuietly(_pendingImage!);
    _pendingImage = null;
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final page = _page, size = _pageSize;
    final w = _effective;
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && _pendingImage != null) _deleteQuietly(_pendingImage!);
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('水印'),
          actions: [
            if (_doc?.watermarkJson != null) TextButton(onPressed: _remove, child: const Text('去掉水印')),
            TextButton(onPressed: _save, child: const Text('保存')),
          ],
        ),
        body: _doc == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(padding: const EdgeInsets.all(16), children: [
                if (page != null && size != null)
                  AspectRatio(
                    aspectRatio: size.width / size.height,
                    child: Stack(fit: StackFit.expand, children: [
                      Image.file(File(_store.file(page.processedFile).path), fit: BoxFit.contain, cacheWidth: 800),
                      CustomPaint(
                        painter: MarkupOverlayPainter(
                          renderer: MarkupRenderer(watermarkImage: _image),
                          imageSize: size,
                          markup: PageMarkup.empty,
                          watermark: w.isEmpty ? null : w,
                        ),
                      ),
                    ]),
                  ),
                const SizedBox(height: 16),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('文字'), icon: Icon(Icons.title)),
                    ButtonSegment(value: true, label: Text('图片'), icon: Icon(Icons.image_outlined)),
                  ],
                  selected: {_useImage},
                  onSelectionChanged: (s) => setState(() => _useImage = s.first),
                ),
                const SizedBox(height: 12),
                if (!_useImage) ...[
                  TextField(
                    controller: _text,
                    maxLength: 40,
                    decoration: const InputDecoration(labelText: '水印文字', border: OutlineInputBorder()),
                    onChanged: (_) => setState(() {}),
                  ),
                  Row(children: [
                    const Text('颜色'),
                    const SizedBox(width: 12),
                    for (final c in _colors)
                      Padding(
                        padding: const EdgeInsets.only(right: 10),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => setState(() => _wm = _wm.copyWith(color: c.toARGB32())),
                          child: CircleAvatar(
                            radius: 14,
                            backgroundColor: c,
                            child: c.toARGB32() == _wm.color ? const Icon(Icons.check, size: 16, color: Colors.white) : null,
                          ),
                        ),
                      ),
                  ]),
                ] else
                  OutlinedButton.icon(
                    onPressed: _pickImage,
                    icon: const Icon(Icons.photo_library_outlined),
                    label: Text(_wm.image == null ? '选择图片（如公司标志）' : '换一张图片'),
                  ),
                _slider('透明度', _wm.opacity, 0.05, 1, (v) => _wm = _wm.copyWith(opacity: v), '${(_wm.opacity * 100).round()}%'),
                _slider('大小', _wm.size, 0.02, 0.2, (v) => _wm = _wm.copyWith(size: v), null),
                _slider('角度', _wm.angle, -90, 90, (v) => _wm = _wm.copyWith(angle: v.roundToDouble()), '${_wm.angle.round()}°'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('铺满整页'),
                  subtitle: const Text('关闭后只在页面中间放一个'),
                  value: _wm.tiled,
                  onChanged: (v) => setState(() => _wm = _wm.copyWith(tiled: v)),
                ),
                const Text('水印在阅读和导出时加到每一页上，不改动原始页面；随时可以修改或去掉。', style: TextStyle(fontSize: 12)),
              ]),
      ),
    );
  }

  Widget _slider(String label, double value, double min, double max, void Function(double) set, String? text) => Row(children: [
        SizedBox(width: 56, child: Text(label)),
        Expanded(
          child: Slider(value: value.clamp(min, max), min: min, max: max, onChanged: (v) => setState(() => set(v))),
        ),
        SizedBox(width: 44, child: Text(text ?? '', textAlign: TextAlign.end)),
      ]);
}
