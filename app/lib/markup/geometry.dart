import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect, Size;

import '../scan/quad.dart';

/// How a processed page relates to its original photo: the crop quad
/// (warped to an upright rectangle, see `ImageOps._warp`) and the clockwise
/// quarter turns applied afterwards.
///
/// Markup and redactions are drawn on the processed image; this maps their
/// coordinates back to the photo (to burn a redaction into it) and across
/// a re-crop or rotation (so markup stays on the same words).
class PageGeometry {
  PageGeometry({required this.originalWidth, required this.originalHeight, this.quad, int rotation = 0})
      : rotation = rotation % 4 {
    if (quad != null) {
      final (w, h) = quad!.targetSize();
      _warpW = w;
      _warpH = h;
      _toRect = _homography(quad!.points, [
        const Offset(0, 0),
        Offset(w - 1.0, 0),
        Offset(w - 1.0, h - 1.0),
        Offset(0, h - 1.0),
      ]);
      _fromRect = _invert(_toRect!);
    } else {
      _warpW = originalWidth;
      _warpH = originalHeight;
    }
  }

  final int originalWidth;
  final int originalHeight;
  final Quad? quad;
  final int rotation;

  late final int _warpW;
  late final int _warpH;
  Float64List? _toRect;
  Float64List? _fromRect;

  /// Size of the processed image.
  Size get processedSize =>
      rotation.isOdd ? Size(_warpH.toDouble(), _warpW.toDouble()) : Size(_warpW.toDouble(), _warpH.toDouble());

  /// Same mapping as the other, so markup needs no remapping.
  bool sameAs(PageGeometry o) =>
      o.originalWidth == originalWidth &&
      o.originalHeight == originalHeight &&
      o.rotation == rotation &&
      (o.quad?.toString() ?? '') == (quad?.toString() ?? '');

  /// Processed-image point -> original-photo point.
  Offset toOriginal(Offset p) {
    final w = _warpW - 1.0, h = _warpH - 1.0;
    // Undo the clockwise turns (see cv.rotate's pixel mapping).
    final warped = switch (rotation) {
      1 => Offset(p.dy, h - p.dx),
      2 => Offset(w - p.dx, h - p.dy),
      3 => Offset(w - p.dy, p.dx),
      _ => p,
    };
    final m = _fromRect;
    return m == null ? warped : _apply(m, warped);
  }

  /// Original-photo point -> processed-image point.
  Offset fromOriginal(Offset p) {
    final m = _toRect;
    final q = m == null ? p : _apply(m, p);
    final w = _warpW - 1.0, h = _warpH - 1.0;
    return switch (rotation) {
      1 => Offset(h - q.dy, q.dx),
      2 => Offset(w - q.dx, h - q.dy),
      3 => Offset(q.dy, w - q.dx),
      _ => q,
    };
  }

  /// Maps a processed-image point of this geometry to the processed image
  /// of [to] (same photo, different crop or rotation).
  Offset remap(Offset p, PageGeometry to) => to.fromOriginal(toOriginal(p));

  /// Axis-aligned bounds of [r] after [remap].
  Rect remapRect(Rect r, PageGeometry to) {
    final pts = [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft].map((p) => remap(p, to)).toList();
    return Rect.fromLTRB(
      pts.map((p) => p.dx).reduce(math.min),
      pts.map((p) => p.dy).reduce(math.min),
      pts.map((p) => p.dx).reduce(math.max),
      pts.map((p) => p.dy).reduce(math.max),
    );
  }

  /// Local scale of [remap] around [p] (how much lengths grow).
  double remapScale(Offset p, PageGeometry to) {
    final a = remap(p, to), b = remap(p + const Offset(10, 0), to), c = remap(p + const Offset(0, 10), to);
    return ((b - a).distance + (c - a).distance) / 20;
  }

  // ------------------------------------------------------------ homography

  static Offset _apply(Float64List m, Offset p) {
    final x = p.dx, y = p.dy;
    final w = m[6] * x + m[7] * y + m[8];
    return Offset((m[0] * x + m[1] * y + m[2]) / w, (m[3] * x + m[4] * y + m[5]) / w);
  }

  /// 3x3 projective transform (row-major) taking [src] onto [dst].
  static Float64List _homography(List<Offset> src, List<Offset> dst) {
    // 8 unknowns (h33 = 1): for each pair two linear equations.
    final a = List.generate(8, (_) => Float64List(9));
    for (var i = 0; i < 4; i++) {
      final x = src[i].dx, y = src[i].dy, u = dst[i].dx, v = dst[i].dy;
      a[2 * i].setAll(0, [x, y, 1, 0, 0, 0, -u * x, -u * y, u]);
      a[2 * i + 1].setAll(0, [0, 0, 0, x, y, 1, -v * x, -v * y, v]);
    }
    final h = _solve(a);
    return Float64List.fromList([...h, 1]);
  }

  /// Gaussian elimination with partial pivoting on an n x (n+1) system.
  static List<double> _solve(List<Float64List> a) {
    final n = a.length;
    for (var col = 0; col < n; col++) {
      var pivot = col;
      for (var r = col + 1; r < n; r++) {
        if (a[r][col].abs() > a[pivot][col].abs()) pivot = r;
      }
      if (a[pivot][col].abs() < 1e-12) throw StateError('退化的四边形');
      final t = a[col];
      a[col] = a[pivot];
      a[pivot] = t;
      for (var r = 0; r < n; r++) {
        if (r == col) continue;
        final f = a[r][col] / a[col][col];
        if (f == 0) continue;
        for (var c = col; c <= n; c++) {
          a[r][c] -= f * a[col][c];
        }
      }
    }
    return [for (var i = 0; i < n; i++) a[i][n] / a[i][i]];
  }

  static Float64List _invert(Float64List m) {
    final a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5], g = m[6], h = m[7], i = m[8];
    final det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
    if (det.abs() < 1e-15) throw StateError('不可逆的变换');
    return Float64List.fromList([
      (e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det, //
      (f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det,
      (d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det,
    ]);
  }
}

/// Width and height from a JPEG's SOF header, without decoding pixels.
/// Null if the bytes are not a JPEG this can parse.
(int, int)? jpegSize(Uint8List b) {
  if (b.length < 4 || b[0] != 0xFF || b[1] != 0xD8) return null;
  var i = 2;
  while (i + 9 < b.length) {
    if (b[i] != 0xFF) return null;
    final marker = b[i + 1];
    if (marker == 0xD8 || (marker >= 0xD0 && marker <= 0xD7) || marker == 0x01) {
      i += 2;
      continue;
    }
    final len = (b[i + 2] << 8) | b[i + 3];
    // SOF0..SOF15 except DHT (C4), JPG (C8), DAC (CC).
    if (marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC) {
      final h = (b[i + 5] << 8) | b[i + 6];
      final w = (b[i + 7] << 8) | b[i + 8];
      return (w, h);
    }
    i += 2 + len;
  }
  return null;
}
