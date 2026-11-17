import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart' show Offset, Paint, Size;

import '../data/db.dart';
import '../data/page_store.dart';
import '../scan/background.dart';
import 'markup.dart';
import 'markup_painter.dart';
import 'watermark.dart';

/// Decodes the images a page's markup (and the watermark) refer to.
/// The caller disposes them with [disposeImages].
Future<Map<String, ui.Image>> loadMarkupImages(PageStore store, Iterable<String> files) async {
  final out = <String, ui.Image>{};
  for (final f in files.toSet()) {
    try {
      final codec = await ui.instantiateImageCodec(await store.file(f).readAsBytes());
      out[f] = (await codec.getNextFrame()).image;
      codec.dispose();
    } catch (_) {
      // A missing signature file just is not drawn.
    }
  }
  return out;
}

void disposeImages(Map<String, ui.Image> images) {
  for (final i in images.values) {
    i.dispose();
  }
}

/// Burns markup and the watermark into a page image for export.
class PageCompositor {
  PageCompositor(this.store);
  final PageStore store;

  /// The page as exported: the processed JPEG itself when there is nothing
  /// to draw, otherwise a new full-resolution JPEG with everything on it.
  Future<Uint8List> compose(ScanPage page, {Watermark? watermark}) async {
    final bytes = await store.file(page.processedFile).readAsBytes();
    final markup = PageMarkup.parse(page.markupJson);
    final wm = (watermark == null || watermark.isEmpty) ? null : watermark;
    if (markup.isEmpty && wm == null) return bytes;

    final codec = await ui.instantiateImageCodec(bytes);
    final base = (await codec.getNextFrame()).image;
    codec.dispose();
    final images = await loadMarkupImages(store, [...markup.imageFiles, ?wm?.image]);
    try {
      final w = base.width, h = base.height;
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawImage(base, Offset.zero, Paint());
      MarkupRenderer(images: images, watermarkImage: wm?.image == null ? null : images[wm!.image])
          .paint(canvas, Size(w.toDouble(), h.toDouble()), markup, watermark: wm);
      final picture = recorder.endRecording();
      final out = await picture.toImage(w, h);
      picture.dispose();
      final rgba = await out.toByteData(format: ui.ImageByteFormat.rawRgba);
      out.dispose();
      return await rgbaToJpegInBackground(rgba!.buffer.asUint8List(), w, h);
    } finally {
      base.dispose();
      disposeImages(images);
    }
  }
}
