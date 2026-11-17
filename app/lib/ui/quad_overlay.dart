import 'package:flutter/material.dart';

import '../scan/quad.dart';

/// Paints [quad] (in image pixels) over an image drawn with BoxFit.contain
/// inside a box of [size]. Shared by the live camera preview and the
/// crop editor.
class QuadPainter extends CustomPainter {
  QuadPainter({required this.quad, required this.imageSize, this.color = const Color(0xFF1A73E8), this.handles = false});

  final Quad? quad;
  final Size imageSize;
  final Color color;
  final bool handles;

  @override
  void paint(Canvas canvas, Size size) {
    final q = quad;
    if (q == null) return;
    final m = ImageMapping(imageSize, size);
    final pts = q.points.map(m.toView).toList();
    final path = Path()..addPolygon(pts, true);
    canvas.drawPath(path, Paint()..color = color.withValues(alpha: 0.18));
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
    if (handles) {
      for (final p in pts) {
        canvas.drawCircle(p, 13, Paint()..color = Colors.white.withValues(alpha: 0.85));
        canvas.drawCircle(
          p,
          13,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3,
        );
      }
    }
  }

  @override
  bool shouldRepaint(QuadPainter old) => old.quad != quad || old.imageSize != imageSize || old.color != color;
}

/// Maps between image pixel coordinates and view coordinates for an image
/// laid out with BoxFit.contain, centered.
class ImageMapping {
  ImageMapping(this.image, this.view)
      : scale = (view.width / image.width) < (view.height / image.height)
            ? view.width / image.width
            : view.height / image.height {
    offset = Offset((view.width - image.width * scale) / 2, (view.height - image.height * scale) / 2);
  }

  final Size image;
  final Size view;
  final double scale;
  late final Offset offset;

  Offset toView(Offset p) => p * scale + offset;
  Offset toImage(Offset v) => (v - offset) / scale;
}
