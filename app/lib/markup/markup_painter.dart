import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../ui/quad_overlay.dart';
import 'markup.dart';
import 'watermark.dart';

/// Draws markup and the watermark in image-pixel coordinates.
///
/// Shared by the editor (scaled into the view) and by export (at full
/// resolution onto the page image), so what is drawn on screen is what ends
/// up in the PDF / JPEG.
class MarkupRenderer {
  MarkupRenderer({this.images = const {}, this.watermarkImage});

  /// Decoded signature images by file name.
  final Map<String, ui.Image> images;
  final ui.Image? watermarkImage;

  void paint(
    Canvas canvas,
    Size imageSize,
    PageMarkup markup, {
    Watermark? watermark,
    int selected = -1,
    double viewScale = 1,
  }) {
    if (watermark != null && !watermark.isEmpty) paintWatermark(canvas, imageSize, watermark);
    for (var i = 0; i < markup.items.length; i++) {
      _item(canvas, markup.items[i]);
    }
    if (selected >= 0 && selected < markup.items.length) _selection(canvas, markup.items[selected], viewScale);
  }

  void _item(Canvas canvas, MarkupItem it) {
    final color = Color(it.color);
    switch (it.kind) {
      case MarkupKind.ink:
        if (it.points.isEmpty) return;
        final paint = Paint()
          ..color = color
          ..strokeWidth = it.width
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round;
        if (it.points.length == 1) {
          canvas.drawCircle(it.points.first, it.width / 2, paint..style = PaintingStyle.fill);
          return;
        }
        canvas.drawPath(smoothPath(it.points), paint);
      case MarkupKind.highlight:
        // Multiply keeps the text under a highlighter readable.
        canvas.drawRect(it.rect, Paint()
          ..color = color
          ..blendMode = BlendMode.multiply);
      case MarkupKind.underline:
        final y = it.rect.bottom - it.width / 2;
        canvas.drawLine(Offset(it.rect.left, y), Offset(it.rect.right, y), _line(color, it.width));
      case MarkupKind.strike:
        final y = it.rect.center.dy;
        canvas.drawLine(Offset(it.rect.left, y), Offset(it.rect.right, y), _line(color, it.width));
      case MarkupKind.text:
        _rotated(canvas, it, () {
          final tp = textPainter(it.text, it.width, color, maxWidth: it.rect.width);
          tp.paint(canvas, it.rect.topLeft);
          tp.dispose();
        });
      case MarkupKind.note:
        _noteIcon(canvas, it.rect);
      case MarkupKind.image:
        final img = images[it.image];
        if (img == null) return;
        _rotated(canvas, it, () {
          canvas.drawImageRect(
            img,
            Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
            it.rect,
            Paint()..filterQuality = FilterQuality.medium,
          );
        });
    }
  }

  static Paint _line(Color c, double w) => Paint()
    ..color = c
    ..strokeWidth = w
    ..strokeCap = StrokeCap.butt;

  static void _rotated(Canvas canvas, MarkupItem it, void Function() draw) {
    if (it.angle == 0) return draw();
    final c = it.rect.center;
    canvas
      ..save()
      ..translate(c.dx, c.dy)
      ..rotate(it.angle)
      ..translate(-c.dx, -c.dy);
    draw();
    canvas.restore();
  }

  /// A small yellow note with a folded corner.
  static void _noteIcon(Canvas canvas, Rect r) {
    final fold = r.width * 0.3;
    final body = Path()
      ..moveTo(r.left, r.top)
      ..lineTo(r.right - fold, r.top)
      ..lineTo(r.right, r.top + fold)
      ..lineTo(r.right, r.bottom)
      ..lineTo(r.left, r.bottom)
      ..close();
    canvas.drawPath(body, Paint()..color = const Color(0xFFFFD54F));
    canvas.drawPath(
      body,
      Paint()
        ..color = const Color(0xFFF9A825)
        ..style = PaintingStyle.stroke
        ..strokeWidth = r.width * 0.05,
    );
    final lines = Paint()
      ..color = const Color(0xAA795548)
      ..strokeWidth = r.width * 0.06;
    for (var k = 1; k <= 3; k++) {
      final y = r.top + r.height * (0.25 + k * 0.17);
      canvas.drawLine(Offset(r.left + r.width * 0.18, y), Offset(r.right - r.width * 0.18, y), lines);
    }
  }

  void _selection(Canvas canvas, MarkupItem it, double viewScale) {
    final paint = Paint()
      ..color = const Color(0xFF1A73E8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2 / viewScale;
    final r = it.bounds.inflate(6 / viewScale);
    if (it.angle != 0 && it.kind != MarkupKind.ink) {
      _rotated(canvas, it, () => canvas.drawRect(it.rect.inflate(6 / viewScale), paint));
    } else {
      canvas.drawRect(r, paint);
    }
  }

  // ------------------------------------------------------------- watermark

  void paintWatermark(Canvas canvas, Size page, Watermark w) {
    final img = w.image != null ? watermarkImage : null;
    if (w.image != null && img == null) return;
    final opacity = w.opacity.clamp(0.02, 1.0);
    final painters = <TextPainter>[];
    final Size tile;
    void Function(Offset centre) draw;
    if (img != null) {
      final width = page.width * (w.size * 5).clamp(0.05, 1.0);
      final height = width * img.height / img.width;
      tile = Size(width, height);
      final paint = Paint()
        ..color = Color.fromRGBO(255, 255, 255, opacity)
        ..filterQuality = FilterQuality.medium;
      final src = Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble());
      draw = (c) => canvas.drawImageRect(img, src, Rect.fromCenter(center: c, width: width, height: height), paint);
    } else {
      final color = Color(w.color).withValues(alpha: opacity);
      final tp = textPainter(w.text, page.width * w.size, color);
      painters.add(tp);
      tile = tp.size;
      draw = (c) => tp.paint(canvas, c - Offset(tile.width / 2, tile.height / 2));
    }
    canvas
      ..save()
      ..clipRect(Offset.zero & page)
      ..translate(page.width / 2, page.height / 2)
      ..rotate(-w.angle * math.pi / 180);
    if (!w.tiled) {
      draw(Offset.zero);
    } else {
      // Cover the page's diagonal in the rotated frame.
      final reach = math.sqrt(page.width * page.width + page.height * page.height) / 2;
      final dx = tile.width * 1.6, dy = math.max(tile.height * 3, page.width * 0.12);
      var row = 0;
      for (var y = -reach; y <= reach; y += dy, row++) {
        final shift = row.isOdd ? dx / 2 : 0;
        for (var x = -reach - shift; x <= reach; x += dx) {
          draw(Offset(x, y));
        }
      }
    }
    canvas.restore();
    for (final tp in painters) {
      tp.dispose();
    }
  }

  // ---------------------------------------------------------------- helpers

  static TextPainter textPainter(String text, double fontSize, Color color, {double? maxWidth}) => TextPainter(
        text: TextSpan(text: text, style: TextStyle(color: color, fontSize: fontSize, height: 1.25)),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: maxWidth ?? double.infinity);

  /// Size a text box needs for [text] at [fontSize].
  static Size measureText(String text, double fontSize, {double? maxWidth}) {
    final tp = textPainter(text, fontSize, const Color(0xFF000000), maxWidth: maxWidth);
    final s = tp.size;
    tp.dispose();
    return s;
  }

  /// Quadratic smoothing through the midpoints, so finger strokes look like
  /// pen strokes instead of polylines.
  static Path smoothPath(List<Offset> pts) {
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    if (pts.length == 2) return path..lineTo(pts[1].dx, pts[1].dy);
    for (var i = 1; i < pts.length - 1; i++) {
      final mid = (pts[i] + pts[i + 1]) / 2;
      path.quadraticBezierTo(pts[i].dx, pts[i].dy, mid.dx, mid.dy);
    }
    return path..lineTo(pts.last.dx, pts.last.dy);
  }
}

/// Paints a page's markup over an image laid out with BoxFit.contain.
class MarkupOverlayPainter extends CustomPainter {
  MarkupOverlayPainter({
    required this.renderer,
    required this.imageSize,
    required this.markup,
    this.watermark,
    this.selected = -1,
    this.preview,
  });

  final MarkupRenderer renderer;
  final Size imageSize;
  final PageMarkup markup;
  final Watermark? watermark;
  final int selected;

  /// Item being drawn right now (not yet in [markup]).
  final MarkupItem? preview;

  @override
  void paint(Canvas canvas, Size size) {
    final m = ImageMapping(imageSize, size);
    canvas
      ..save()
      ..translate(m.offset.dx, m.offset.dy)
      ..scale(m.scale);
    final all = preview == null ? markup : markup.add(preview!);
    renderer.paint(canvas, imageSize, all, watermark: watermark, selected: selected, viewScale: m.scale);
    canvas.restore();
  }

  @override
  bool shouldRepaint(MarkupOverlayPainter old) =>
      old.markup != markup ||
      old.preview != preview ||
      old.selected != selected ||
      old.watermark != watermark ||
      old.imageSize != imageSize ||
      old.renderer != renderer;
}
