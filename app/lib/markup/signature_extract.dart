import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;

/// Ink colour for an extracted signature or stamp.
enum InkColor {
  original('原色', null),
  black('黑', (20, 20, 20)),
  blue('蓝', (190, 60, 20)), // BGR
  red('红', (40, 40, 210));

  const InkColor(this.label, this.bgr);
  final String label;
  final (int, int, int)? bgr;
}

/// Lifts a signature or stamp off a photo: the paper becomes transparent,
/// the ink keeps its colour (or takes [color]). Returns a PNG with alpha,
/// trimmed to the ink.
///
/// [crop] is (x, y, w, h) in photo pixels; null uses the whole photo.
/// [strength] 0..1 moves the ink threshold: higher keeps fainter strokes.
Uint8List extractSignature(Uint8List photo, {(int, int, int, int)? crop, double strength = 0.5, InkColor color = InkColor.original}) {
  final owned = <cv.Mat>[];
  T keep<T extends cv.Mat>(T m) {
    owned.add(m);
    return m;
  }

  try {
    var img = keep(cv.imdecode(photo, cv.IMREAD_COLOR));
    if (img.isEmpty) throw const FormatException('无法解码图片');
    if (crop != null) {
      final (x, y, w, h) = crop;
      final cx = x.clamp(0, img.cols - 1), cy = y.clamp(0, img.rows - 1);
      img = keep(img.region(cv.Rect(cx, cy, w.clamp(1, img.cols - cx), h.clamp(1, img.rows - cy))).clone());
    }
    final s = 1600 / math.max(img.cols, img.rows);
    if (s < 1) img = keep(cv.resize(img, ((img.cols * s).round(), (img.rows * s).round()), interpolation: cv.INTER_AREA));

    // Flatten uneven lighting: divide by a blurred "paper" estimate, so
    // shadows across the paper do not turn into ink.
    final gray = keep(cv.cvtColor(img, cv.COLOR_BGR2GRAY));
    final k = math.max(15, (math.max(img.cols, img.rows) / 25).round()) | 1;
    final kernel = keep(cv.getStructuringElement(cv.MORPH_RECT, (k, k)));
    final paper = keep(cv.medianBlur(keep(cv.dilate(gray, kernel)), 21));
    final flat = keep(cv.divide(gray, paper, scale: 255));

    // Ink is darker than the paper; strength moves the cut-off between
    // "only dark strokes" (0) and "faint strokes too" (1).
    final cut = 140 + 90 * strength.clamp(0.0, 1.0);
    final (_, hard) = cv.threshold(flat, cut, 255, cv.THRESH_BINARY_INV);
    keep(hard);
    // Soft edge for anti-aliasing: darker = more opaque inside the mask.
    final white = keep(cv.Mat.fromScalar(flat.rows, flat.cols, cv.MatType.CV_8UC1, cv.Scalar.all(255)));
    final soft = keep(cv.subtract(white, flat));
    final alpha = keep(cv.bitwiseAND(keep(cv.convertScaleAbs(soft, alpha: 2.2)), hard));

    // Trim to the ink, with a small margin.
    final pts = keep(cv.findNonZero(hard));
    if (pts.isEmpty) throw const FormatException('没有找到笔迹，试试调高"笔迹浓淡"');
    final vec = cv.VecPoint.fromMat(pts);
    final box = cv.boundingRect(vec);
    vec.dispose();
    final pad = math.max(4, (math.max(box.width, box.height) * 0.04).round());
    final x0 = math.max(0, box.x - pad), y0 = math.max(0, box.y - pad);
    final roi = cv.Rect(x0, y0, math.min(img.cols - x0, box.width + 2 * pad), math.min(img.rows - y0, box.height + 2 * pad));

    final cImg = keep(img.region(roi).clone());
    final cAlpha = keep(alpha.region(roi).clone());
    final bgr = color.bgr;
    final ink = bgr == null
        ? cImg
        : keep(cv.Mat.fromScalar(cImg.rows, cImg.cols, cv.MatType.CV_8UC3, cv.Scalar(bgr.$1.toDouble(), bgr.$2.toDouble(), bgr.$3.toDouble())));
    final ch = cv.split(ink);
    final planes = cv.VecMat.fromList([ch[0], ch[1], ch[2], cAlpha]);
    final bgra = keep(cv.merge(planes));
    planes.dispose();
    ch.dispose();
    final (ok, png) = cv.imencode('.png', bgra);
    if (!ok) throw StateError('PNG 编码失败');
    return png;
  } finally {
    for (final m in owned.reversed) {
      m.dispose();
    }
  }
}

Future<Uint8List> extractSignatureInBackground(
  Uint8List photo, {
  (int, int, int, int)? crop,
  double strength = 0.5,
  InkColor color = InkColor.original,
}) =>
    Isolate.run(() => extractSignature(photo, crop: crop, strength: strength, color: color));
