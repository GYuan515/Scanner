import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../scan/quad.dart';
import 'quad_overlay.dart';

/// Radius of the loupe in logical pixels.
const double loupeRadius = 58;

/// Keeps the loupe away from the view edges by this much.
const double _loupeMargin = 8;

/// Places the loupe in whichever view corner is farthest from [point], so
/// it does not sit under the finger that is dragging.
Offset loupeCenter(Size view, Offset point, {double radius = loupeRadius}) {
  final inset = radius + _loupeMargin;
  // A narrow view cannot fit the loupe on either side; center it instead.
  final x = math.max(inset, view.width - inset) <= inset ? view.width / 2 : inset;
  final y = math.max(inset, view.height - inset) <= inset ? view.height / 2 : inset;
  final candidates = [
    Offset(x, y),
    Offset(view.width - x, y),
    Offset(x, view.height - y),
    Offset(view.width - x, view.height - y),
  ];
  var best = candidates.first;
  var bestD = -1.0;
  for (final c in candidates) {
    final d = (c - point).distanceSquared;
    if (d > bestD) {
      bestD = d;
      best = c;
    }
  }
  return best;
}

/// Draws a circular magnified view of the area around [corner] while a
/// crop handle is being dragged, with the outline and a crosshair on top so
/// the exact pixel under the finger stays visible.
class LoupePainter extends CustomPainter {
  LoupePainter({
    required this.image,
    required this.imageSize,
    required this.quad,
    required this.corner,
    this.zoom = 2.5,
    this.radius = loupeRadius,
    this.color = const Color(0xFF1A73E8),
  });

  final ui.Image image;
  final Size imageSize;
  final Quad quad;

  /// The dragged corner, in image pixels.
  final Offset corner;

  final double zoom;
  final double radius;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final m = ImageMapping(imageSize, size);
    final center = loupeCenter(size, m.toView(corner), radius: radius);
    // Image pixels per logical pixel inside the loupe.
    final k = m.scale * zoom;
    if (k <= 0) return;
    final srcRadius = radius / k;
    final src = Rect.fromCircle(center: corner, radius: srcRadius)
        .intersect(Rect.fromLTWH(0, 0, imageSize.width, imageSize.height));
    if (src.isEmpty) return;

    Offset toLoupe(Offset p) => (p - corner) * k + center;
    final circle = Rect.fromCircle(center: center, radius: radius);

    canvas.save();
    canvas.clipPath(Path()..addOval(circle));
    // The source rect is clipped to the image, so outside the page edge the
    // backdrop shows through instead of stretched pixels.
    canvas.drawRect(circle, Paint()..color = const Color(0xFF202124));
    canvas.drawImageRect(
      image,
      src,
      Rect.fromPoints(toLoupe(src.topLeft), toLoupe(src.bottomRight)),
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.drawPath(
      Path()..addPolygon(quad.points.map(toLoupe).toList(), true),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    final cross = Paint()
      ..color = Colors.white.withValues(alpha: 0.9)
      ..strokeWidth = 1.2;
    canvas.drawLine(center - const Offset(14, 0), center + const Offset(14, 0), cross);
    canvas.drawLine(center - const Offset(0, 14), center + const Offset(0, 14), cross);
    canvas.restore();

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(LoupePainter old) =>
      old.image != image || old.imageSize != imageSize || old.quad != quad || old.corner != corner || old.zoom != zoom;
}
