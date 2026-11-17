import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../data/db.dart';
import '../data/page_store.dart';
import '../markup/compositor.dart';
import '../markup/markup.dart';
import '../markup/markup_painter.dart';
import '../markup/watermark.dart';
import 'image_size.dart';

/// A processed page with its markup (and optionally the watermark) drawn
/// on top, laid out with BoxFit.contain. Used wherever a page is viewed.
class MarkedPage extends StatefulWidget {
  const MarkedPage({super.key, required this.page, required this.store, this.watermark});
  final ScanPage page;
  final PageStore store;
  final Watermark? watermark;

  @override
  State<MarkedPage> createState() => _MarkedPageState();
}

class _MarkedPageState extends State<MarkedPage> {
  Size? _size;
  Map<String, ui.Image> _images = const {};
  String? _loadedFor;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(MarkedPage old) {
    super.didUpdateWidget(old);
    if (old.page.processedFile != widget.page.processedFile ||
        old.page.markupJson != widget.page.markupJson ||
        old.watermark?.toJsonString() != widget.watermark?.toJsonString()) {
      _load();
    }
  }

  @override
  void dispose() {
    disposeImages(_images);
    super.dispose();
  }

  Future<void> _load() async {
    final pg = widget.page;
    final key = '${pg.processedFile}|${pg.markupJson}|${widget.watermark?.image}';
    _loadedFor = key;
    final markup = PageMarkup.parse(pg.markupJson);
    final wmImage = widget.watermark?.image;
    if (markup.isEmpty && (widget.watermark == null || widget.watermark!.isEmpty)) {
      final old = _images;
      _images = const {};
      if (mounted) setState(() => _size = null);
      disposeImages(old);
      return;
    }
    final size = await imageSizeOf(widget.store.file(pg.processedFile).path);
    final images = await loadMarkupImages(widget.store, [...markup.imageFiles, ?wmImage]);
    if (!mounted || _loadedFor != key) {
      disposeImages(images);
      return;
    }
    final old = _images;
    setState(() {
      _size = size;
      _images = images;
    });
    disposeImages(old);
  }

  @override
  Widget build(BuildContext context) {
    final pg = widget.page;
    final image = Image.file(File(widget.store.file(pg.processedFile).path), key: ValueKey(pg.processedFile), fit: BoxFit.contain);
    final size = _size;
    if (size == null) return image;
    final wm = widget.watermark;
    return Stack(fit: StackFit.expand, children: [
      image,
      CustomPaint(
        painter: MarkupOverlayPainter(
          renderer: MarkupRenderer(images: _images, watermarkImage: wm?.image == null ? null : _images[wm!.image]),
          imageSize: size,
          markup: PageMarkup.parse(pg.markupJson),
          watermark: wm,
        ),
      ),
    ]);
  }
}
