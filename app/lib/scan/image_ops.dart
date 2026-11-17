import 'dart:math' as math;
import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;

import 'edge_detector.dart';
import 'quad.dart';

/// Result of [ImageOps.prepare]; plain data so it can cross isolates.
class PreparedImage {
  const PreparedImage(this.bytes, this.width, this.height, this.quad);
  final Uint8List bytes;
  final int width;
  final int height;
  final Quad? quad;
}

enum ScanFilter {
  original('原图'),
  enhance('增强'),
  shadowRemoval('去阴影'),
  grayscale('灰度'),
  blackWhite('黑白'),
  inkSaver('省墨'),
  sharpen('锐化'),
  brighten('提亮');

  const ScanFilter(this.label);
  final String label;
}

/// Pure image operations on encoded bytes. Every function decodes,
/// processes and re-encodes so callers can run them in an isolate
/// (`Isolate.run`) without passing native handles across.
class ImageOps {
  static const int jpegQuality = 92;

  /// Perspective-corrects [src] to the rectangle spanned by [quad],
  /// then applies [filter] and [rotateQuarterTurns] (clockwise).
  ///
  /// [maxSide] downsizes the source first (and scales [quad] to match);
  /// used for fast on-screen previews.
  static Uint8List process(
    Uint8List src, {
    Quad? quad,
    ScanFilter filter = ScanFilter.enhance,
    int rotateQuarterTurns = 0,
    int? maxSide,
  }) {
    final img = cv.imdecode(src, cv.IMREAD_COLOR);
    final owned = <cv.Mat>[img];
    try {
      var cur = img;
      if (img.isEmpty) throw const FormatException('无法解码图片');
      if (maxSide != null) {
        final s = maxSide / math.max(img.cols, img.rows);
        if (s < 1) {
          cur = cv.resize(img, ((img.cols * s).round(), (img.rows * s).round()), interpolation: cv.INTER_AREA);
          owned.add(cur);
          quad = quad?.scale(cur.cols / img.cols, cur.rows / img.rows);
        }
      }
      if (quad != null) {
        cur = _warp(cur, quad);
        owned.add(cur);
      }
      final filtered = applyFilter(cur, filter);
      owned.add(filtered);
      cur = filtered;
      final turns = rotateQuarterTurns % 4;
      if (turns != 0) {
        final code = switch (turns) {
          1 => cv.ROTATE_90_CLOCKWISE,
          2 => cv.ROTATE_180,
          _ => cv.ROTATE_90_COUNTERCLOCKWISE,
        };
        cur = cv.rotate(cur, code);
        owned.add(cur);
      }
      return encodeJpeg(cur);
    } finally {
      for (final m in owned) {
        m.dispose();
      }
    }
  }

  /// Decodes a camera/gallery photo (applying its EXIF orientation),
  /// caps its size, re-encodes it without EXIF and detects the page
  /// outline. After this, pixel coordinates mean the same thing to
  /// OpenCV and to Flutter's image widgets.
  static PreparedImage prepare(Uint8List src, {int maxSide = 4096}) {
    final img = cv.imdecode(src, cv.IMREAD_COLOR);
    final owned = <cv.Mat>[img];
    try {
      if (img.isEmpty) throw const FormatException('无法解码图片');
      var cur = img;
      final s = maxSide / math.max(img.cols, img.rows);
      if (s < 1) {
        cur = cv.resize(img, ((img.cols * s).round(), (img.rows * s).round()), interpolation: cv.INTER_AREA);
        owned.add(cur);
      }
      final quad = EdgeDetector.detect(cur);
      return PreparedImage(encodeJpeg(cur, quality: 95), cur.cols, cur.rows, quad);
    } finally {
      for (final m in owned) {
        m.dispose();
      }
    }
  }

  static Uint8List encodeJpeg(cv.Mat m, {int quality = jpegQuality}) {
    final (ok, bytes) = cv.imencode('.jpg', m, params: cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, quality]));
    if (!ok) throw StateError('JPEG encoding failed');
    return bytes;
  }

  /// Downscaled JPEG for thumbnails and previews.
  static Uint8List thumbnail(Uint8List src, {int maxSide = 480}) {
    final img = cv.imdecode(src, cv.IMREAD_COLOR);
    try {
      final s = maxSide / math.max(img.cols, img.rows);
      if (s >= 1) return encodeJpeg(img, quality: 80);
      final small = cv.resize(img, ((img.cols * s).round(), (img.rows * s).round()), interpolation: cv.INTER_AREA);
      try {
        return encodeJpeg(small, quality: 80);
      } finally {
        small.dispose();
      }
    } finally {
      img.dispose();
    }
  }

  static cv.Mat _warp(cv.Mat img, Quad quad) {
    final (w, h) = quad.targetSize();
    final src = cv.VecPoint2f.fromList([for (final p in quad.points) cv.Point2f(p.dx, p.dy)]);
    final dst = cv.VecPoint2f.fromList([
      cv.Point2f(0, 0),
      cv.Point2f(w - 1, 0),
      cv.Point2f(w - 1, h - 1),
      cv.Point2f(0, h - 1),
    ]);
    final m = cv.getPerspectiveTransform2f(src, dst);
    try {
      return cv.warpPerspective(img, m, (w, h), flags: cv.INTER_CUBIC, borderMode: cv.BORDER_REPLICATE);
    } finally {
      m.dispose();
      src.dispose();
      dst.dispose();
    }
  }

  /// Re-encodes [src] with its longest side at most [maxSide] and the given
  /// JPEG [quality], for smaller exports. Never enlarges.
  static Uint8List recompress(Uint8List src, int maxSide, int quality) {
    final img = cv.imdecode(src, cv.IMREAD_COLOR);
    cv.Mat? small;
    try {
      if (img.isEmpty) throw const FormatException('无法解码图片');
      final s = maxSide / math.max(img.cols, img.rows);
      if (s < 1) small = cv.resize(img, ((img.cols * s).round(), (img.rows * s).round()), interpolation: cv.INTER_AREA);
      return encodeJpeg(small ?? img, quality: quality);
    } finally {
      small?.dispose();
      img.dispose();
    }
  }

  /// Pixel size of an encoded image.
  static (int, int) sizeOf(Uint8List src) {
    final img = cv.imdecode(src, cv.IMREAD_COLOR);
    try {
      if (img.isEmpty) throw const FormatException('无法解码图片');
      return (img.cols, img.rows);
    } finally {
      img.dispose();
    }
  }

  /// Paints [polygons] (image pixels) solid black into the JPEG [src] and
  /// re-encodes it. Used for redaction, so the covered pixels are gone from
  /// the file itself, not hidden under a layer.
  static Uint8List blackOut(Uint8List src, List<List<(double, double)>> polygons, {int quality = 95}) {
    final img = cv.imdecode(src, cv.IMREAD_COLOR);
    try {
      if (img.isEmpty) throw const FormatException('无法解码图片');
      final pts = cv.VecVecPoint.fromList([
        for (final poly in polygons) [for (final (x, y) in poly) cv.Point(x.round(), y.round())],
      ]);
      cv.fillPoly(img, pts, cv.Scalar(0, 0, 0, 0));
      pts.dispose();
      return encodeJpeg(img, quality: quality);
    } finally {
      img.dispose();
    }
  }

  /// Returns a new 3-channel BGR Mat; [bgr] is not modified.
  static cv.Mat applyFilter(cv.Mat bgr, ScanFilter filter) {
    switch (filter) {
      case ScanFilter.original:
        return bgr.clone();
      case ScanFilter.grayscale:
        return _toBgr(cv.cvtColor(bgr, cv.COLOR_BGR2GRAY));
      case ScanFilter.enhance:
        return _enhance(bgr);
      case ScanFilter.shadowRemoval:
        return _removeShadows(bgr);
      case ScanFilter.blackWhite:
        return _toBgr(_binarize(bgr, c: 12));
      case ScanFilter.inkSaver:
        // Like black & white but with a larger offset so thin noise and
        // light backgrounds drop out completely.
        return _toBgr(_binarize(bgr, c: 22));
      case ScanFilter.sharpen:
        return _sharpen(bgr);
      case ScanFilter.brighten:
        return _brighten(bgr);
    }
  }

  /// Unsharp mask: original + 0.8 x (original - blurred).
  static cv.Mat _sharpen(cv.Mat bgr) {
    final blur = cv.gaussianBlur(bgr, (0, 0), 2.0);
    try {
      return cv.addWeighted(bgr, 1.8, blur, -0.8, 0);
    } finally {
      blur.dispose();
    }
  }

  /// Gamma 0.7 lifts dark and mid tones without clipping highlights,
  /// which suits photos taken in dim light.
  static cv.Mat _brighten(cv.Mat bgr) {
    final table = Uint8List.fromList([for (var i = 0; i < 256; i++) (255 * math.pow(i / 255, 0.7)).round().clamp(0, 255)]);
    final lut = cv.Mat.fromList(1, 256, cv.MatType.CV_8UC1, table);
    try {
      return cv.LUT(bgr, lut);
    } finally {
      lut.dispose();
    }
  }

  /// Stacks pages vertically into one tall JPEG, each scaled to the same
  /// width with a white gap between them. Width is capped at [maxWidth]
  /// and the total height at [maxHeight] (JPEG's hard limit is 65535).
  static Uint8List stitchVertical(List<Uint8List> pages, {int maxWidth = 1600, int gap = 24, int maxHeight = 60000}) {
    if (pages.isEmpty) throw ArgumentError('没有页面');
    final mats = <cv.Mat>[];
    try {
      for (final b in pages) {
        final m = cv.imdecode(b, cv.IMREAD_COLOR);
        if (m.isEmpty) throw const FormatException('无法解码图片');
        mats.add(m);
      }
      var width = math.min(maxWidth, mats.map((m) => m.cols).reduce(math.max));
      int heightAt(int w) =>
          mats.fold<int>(0, (s, m) => s + (m.rows * w / m.cols).round()) + gap * (mats.length - 1);
      final total = heightAt(width);
      if (total > maxHeight) width = (width * maxHeight / total).floor();
      final out = cv.Mat.fromScalar(heightAt(width), width, cv.MatType.CV_8UC3, cv.Scalar.all(255));
      try {
        var y = 0;
        for (final m in mats) {
          final h = (m.rows * width / m.cols).round();
          final scaled = cv.resize(m, (width, h), interpolation: width < m.cols ? cv.INTER_AREA : cv.INTER_CUBIC);
          final roi = out.region(cv.Rect(0, y, width, h));
          scaled.copyTo(roi);
          roi.dispose();
          scaled.dispose();
          y += h + gap;
        }
        return encodeJpeg(out, quality: 88);
      } finally {
        out.dispose();
      }
    } finally {
      for (final m in mats) {
        m.dispose();
      }
    }
  }

  /// Converts BGRA pixels (as rendered by PDFium) to an EXIF-free JPEG.
  static Uint8List bgraToJpeg(Uint8List bgra, int width, int height, {int quality = 95}) =>
      _fourChannelToJpeg(bgra, width, height, cv.COLOR_BGRA2BGR, quality);

  /// Pixels from dart:ui (`ImageByteFormat.rawRgba`) to JPEG.
  static Uint8List rgbaToJpeg(Uint8List rgba, int width, int height) => _fourChannelToJpeg(rgba, width, height, cv.COLOR_RGBA2BGR, 95);

  static Uint8List _fourChannelToJpeg(Uint8List px, int width, int height, int code, int quality) {
    if (px.length != width * height * 4) throw ArgumentError('像素数量不对');
    // Bulk copy into native memory; Mat.fromList copies element by element,
    // which takes seconds for a full page.
    final m = cv.Mat.create(rows: height, cols: width, type: cv.MatType.CV_8UC4);
    cv.Mat? bgr;
    try {
      m.data.setAll(0, px);
      bgr = cv.cvtColor(m, code);
      return encodeJpeg(bgr, quality: quality);
    } finally {
      m.dispose();
      bgr?.dispose();
    }
  }

  /// Contrast boost on the lightness channel only (CLAHE in Lab), which
  /// keeps colors natural while making text crisper.
  static cv.Mat _enhance(cv.Mat bgr) {
    final lab = cv.cvtColor(bgr, cv.COLOR_BGR2Lab);
    final ch = cv.split(lab);
    final clahe = cv.createCLAHE(clipLimit: 2.0, tileGridSize: (8, 8));
    final l2 = clahe.apply(ch[0]);
    final merged = cv.merge(cv.VecMat.fromList([l2, ch[1], ch[2]]));
    final out = cv.cvtColor(merged, cv.COLOR_Lab2BGR);
    lab.dispose();
    l2.dispose();
    merged.dispose();
    ch.dispose();
    clahe.dispose();
    return out;
  }

  /// Divides each channel by an estimate of its background (large dilate
  /// + median blur). Paper becomes uniformly white, shadows disappear,
  /// ink and colors are preserved.
  static cv.Mat _removeShadows(cv.Mat bgr) {
    final ch = cv.split(bgr);
    final kernel = cv.getStructuringElement(cv.MORPH_RECT, (7, 7));
    final ksize = _oddAtLeast(math.min(bgr.cols, bgr.rows) ~/ 30, 21);
    final outs = <cv.Mat>[];
    for (var i = 0; i < ch.length; i++) {
      final dil = cv.dilate(ch[i], kernel);
      final bg = cv.medianBlur(dil, ksize);
      outs.add(cv.divide(ch[i], bg, scale: 255));
      dil.dispose();
      bg.dispose();
    }
    final merged = cv.merge(cv.VecMat.fromList(outs));
    for (final m in outs) {
      m.dispose();
    }
    kernel.dispose();
    ch.dispose();
    return merged;
  }

  static cv.Mat _binarize(cv.Mat bgr, {required double c}) {
    final flat = _removeShadows(bgr);
    final gray = cv.cvtColor(flat, cv.COLOR_BGR2GRAY);
    final block = _oddAtLeast(math.min(bgr.cols, bgr.rows) ~/ 40, 15);
    final bin = cv.adaptiveThreshold(gray, 255, cv.ADAPTIVE_THRESH_GAUSSIAN_C, cv.THRESH_BINARY, block, c);
    flat.dispose();
    gray.dispose();
    return bin;
  }

  static cv.Mat _toBgr(cv.Mat gray) {
    final out = cv.cvtColor(gray, cv.COLOR_GRAY2BGR);
    gray.dispose();
    return out;
  }

  static int _oddAtLeast(int v, int min) {
    final x = math.max(v, min);
    return x.isOdd ? x : x + 1;
  }
}
