import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:opencv_dart/opencv_dart.dart' as cv;

import 'quad.dart';

/// Finds the document outline in a photo with classic OpenCV:
/// downscale, grayscale, blur, Canny, close gaps, then pick the largest
/// convex 4-point contour. Returns null if nothing plausible is found.
class EdgeDetector {
  /// Images are processed at this longest side for speed; the result is
  /// scaled back to the original resolution.
  static const int workSize = 640;

  /// A detected page must cover at least this fraction of the frame.
  static const double minAreaRatio = 0.12;

  static Quad? detectBytes(Uint8List encoded) {
    final img = cv.imdecode(encoded, cv.IMREAD_COLOR);
    try {
      if (img.isEmpty) return null;
      return detect(img);
    } finally {
      img.dispose();
    }
  }

  /// Live-preview variant: [y] is the luminance plane of a camera frame
  /// (`CameraImage.planes[0]`), possibly with row padding. Corners are in
  /// the frame's sensor coordinates (before any display rotation).
  static Quad? detectLuma(Uint8List y, int width, int height, int bytesPerRow) {
    // Nearest-neighbour subsample in Dart first: Mat.fromList copies
    // element by element, so keep the buffer small.
    final step = math.max(1, (math.max(width, height) / 360).ceil());
    final sw = width ~/ step, sh = height ~/ step;
    final packed = Uint8List(sw * sh);
    for (var r = 0; r < sh; r++) {
      final src = r * step * bytesPerRow;
      final dst = r * sw;
      for (var c = 0; c < sw; c++) {
        packed[dst + c] = y[src + c * step];
      }
    }
    final gray = cv.Mat.fromList(sh, sw, cv.MatType.CV_8UC1, packed);
    try {
      return _detectGray(gray)?.scale(step.toDouble(), step.toDouble());
    } finally {
      gray.dispose();
    }
  }

  /// [bgr] is a 3-channel image. Corners are returned in its pixel space.
  static Quad? detect(cv.Mat bgr) {
    final gray = cv.cvtColor(bgr, cv.COLOR_BGR2GRAY);
    try {
      return _detectGray(gray);
    } finally {
      gray.dispose();
    }
  }

  static Quad? _detectGray(cv.Mat fullGray) {
    final w = fullGray.cols, h = fullGray.rows;
    final scale = workSize / math.max(w, h);
    final gray = scale < 1
        ? cv.resize(fullGray, ((w * scale).round(), (h * scale).round()), interpolation: cv.INTER_AREA)
        : fullGray.clone();
    final s = scale < 1 ? scale : 1.0;
    final disposables = <cv.Mat>[gray];
    try {
      final small = gray;
      final blur = cv.gaussianBlur(gray, (5, 5), 0);
      disposables.add(blur);

      // Try a few Canny thresholds; the median-based one first.
      final median = _median(blur);
      final attempts = <(double, double)>[
        (math.max(0, 0.66 * median), math.min(255, 1.33 * median)),
        (30, 90),
        (75, 200),
      ];
      final kernel = cv.getStructuringElement(cv.MORPH_RECT, (5, 5));
      disposables.add(kernel);
      for (final (lo, hi) in attempts) {
        final edges = cv.canny(blur, lo, hi);
        final closed = cv.morphologyEx(edges, cv.MORPH_CLOSE, kernel, iterations: 2);
        disposables
          ..add(edges)
          ..add(closed);
        final quad = _bestQuad(closed, small.cols * small.rows.toDouble());
        if (quad != null) {
          return quad.scale(1 / s, 1 / s).clamp(w.toDouble(), h.toDouble());
        }
      }
      return null;
    } finally {
      for (final m in disposables) {
        m.dispose();
      }
    }
  }

  static Quad? _bestQuad(cv.Mat edges, double frameArea) {
    final (contours, hierarchy) = cv.findContours(edges, cv.RETR_LIST, cv.CHAIN_APPROX_SIMPLE);
    try {
      Quad? best;
      var bestArea = frameArea * minAreaRatio;
      for (final c in contours) {
        final area = cv.contourArea(c);
        if (area < bestArea) continue;
        final peri = cv.arcLength(c, true);
        final approx = cv.approxPolyDP(c, 0.02 * peri, true);
        try {
          List<Offset>? pts;
          if (approx.length == 4) {
            pts = [for (final p in approx) Offset(p.x.toDouble(), p.y.toDouble())];
          } else if (approx.length > 4 && approx.length <= 8) {
            // Rounded or partly occluded corners: fall back to the
            // minimum-area rectangle around the contour.
            final rect = cv.minAreaRect(c);
            pts = [for (final p in rect.points) Offset(p.x, p.y)];
          }
          if (pts == null) continue;
          final q = Quad.ordered(pts);
          if (!q.isConvex) continue;
          final qa = q.area;
          if (qa > bestArea) {
            bestArea = qa;
            best = q;
          }
        } finally {
          approx.dispose();
        }
      }
      return best;
    } finally {
      contours.dispose();
      hierarchy.dispose();
    }
  }

  static double _median(cv.Mat gray) {
    // Sampling every 4th pixel is enough for a threshold estimate.
    // `data` is only contiguous for continuous Mats, which ours are.
    final data = gray.data;
    final hist = List<int>.filled(256, 0);
    var n = 0;
    for (var i = 0; i < data.length; i += 4) {
      hist[data[i]]++;
      n++;
    }
    final half = n / 2;
    var acc = 0;
    for (var v = 0; v < 256; v++) {
      acc += hist[v];
      if (acc >= half) return v.toDouble();
    }
    return 127;
  }
}
