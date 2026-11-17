import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:opencv_dart/opencv_dart.dart' as cv;

import 'ocr_result.dart';

/// Model inference, kept behind an interface so the pipeline can be tested
/// without ONNX Runtime (which only exists on the device).
///
/// All images are uint8 BGR, NHWC, rows packed without padding.
abstract class OcrBackend {
  /// Text probability map for one [height] x [width] image, one byte per
  /// pixel (probability * 255).
  Future<Uint8List> detect(Uint8List bgr, int height, int width);

  /// Line orientation for [n] crops of [OcrPipeline.clsHeight] x
  /// [OcrPipeline.clsWidth]: probabilities `[p0, p180]` per crop.
  Future<Float32List> orientation(Uint8List bgr, int n);

  /// Greedy CTC input for [n] crops of 48 x [width]: the best class per
  /// time step and its probability, each `n * steps` long.
  Future<RecOutput> recognize(Uint8List bgr, int n, int width);
}

class RecOutput {
  const RecOutput(this.index, this.prob, this.steps);
  final Int32List index;
  final Float32List prob;
  final int steps;
}

/// PP-OCR style detection + recognition, written against OpenCV.
///
/// Mirrors RapidOCR's defaults (DB thresholds 0.3 / 0.5, unclip 1.6, text
/// score 0.5) so results match the Python reference in `tool/`.
class OcrPipeline {
  OcrPipeline(this.backend, this.keys, {this.detMaxSide = 1600});

  final OcrBackend backend;

  /// Index 0 is the CTC blank; the last entry is a space.
  final List<String> keys;
  final int detMaxSide;

  static const recHeight = 48;
  static const recBatch = 6;
  static const recMaxWidth = 1600;
  static const clsHeight = 80;
  static const clsWidth = 160;
  static const clsBatch = 8;

  static const binThresh = 0.3;
  static const boxThresh = 0.5;
  static const unclipRatio = 1.6;
  static const minTextScore = 0.5;
  static const clsThresh = 0.9;

  /// Builds the key list from the dictionary file contents.
  static List<String> keysFrom(String dict) => ['', ...dict.split('\n'), ' '];

  /// Reads all text in [image] (BGR). With [region] only that part is read;
  /// coordinates in the result still refer to the whole image.
  Future<OcrResult> run(cv.Mat image, {cv.Rect? region}) async {
    final owned = <cv.Mat>[];
    try {
      var src = image;
      var origin = Offset.zero;
      if (region != null) {
        src = image.region(region);
        owned.add(src);
        origin = Offset(region.x.toDouble(), region.y.toDouble());
      }
      var boxes = await _detect(src);
      // A selection around a single word may be too tight for the detector;
      // then read the whole selection as one line.
      if (boxes.isEmpty && region != null) {
        final w = src.cols.toDouble(), h = src.rows.toDouble();
        boxes = [
          [Offset.zero, Offset(w, 0), Offset(w, h), Offset(0, h)],
        ];
      }
      final lines = await _recognize(src, boxes);
      final shifted = [
        for (final l in lines) OcrLine([for (final p in l.box) p + origin], l.text, l.score),
      ];
      return OcrResult(width: image.cols, height: image.rows, rows: OcrResult.arrange(shifted));
    } finally {
      for (final m in owned) {
        m.dispose();
      }
    }
  }

  // ------------------------------------------------------------- detection

  /// Scale for the detector input: at most [detMaxSide] on the long side,
  /// small images enlarged so the short side reaches 736 (small text needs
  /// the extra pixels), sides rounded to multiples of 32.
  static (int, int) detSize(int width, int height, int maxSide) {
    final longSide = math.max(width, height), shortSide = math.min(width, height);
    final r = math.min(maxSide / longSide, math.max(1.0, 736 / shortSide));
    int round32(double v) => math.max(32, (v / 32).round() * 32);
    return (round32(width * r), round32(height * r));
  }

  Future<List<List<Offset>>> _detect(cv.Mat src) async {
    final (w, h) = detSize(src.cols, src.rows, detMaxSide);
    final small = cv.resize(src, (w, h), interpolation: cv.INTER_LINEAR);
    final Uint8List map;
    try {
      map = await backend.detect(_packed(small), h, w);
    } finally {
      small.dispose();
    }
    final sx = src.cols / w, sy = src.rows / h;
    return [
      for (final box in boxesFromMap(map, w, h))
        _clampBox([for (final p in box) Offset(p.dx * sx, p.dy * sy)], src.cols, src.rows),
    ];
  }

  /// DB post-processing: threshold the probability map, take each blob's
  /// minimum-area rectangle, drop low-scoring ones and grow the rest by the
  /// unclip distance (area * ratio / perimeter, as pyclipper does for a
  /// rectangle). Returns boxes ordered tl, tr, br, bl in map pixels.
  static List<List<Offset>> boxesFromMap(Uint8List map, int width, int height) {
    if (map.length != width * height) throw ArgumentError('概率图大小不对：${map.length} != $width x $height');
    final prob = cv.Mat.create(rows: height, cols: width, type: cv.MatType.CV_8UC1);
    cv.Mat? mask;
    cv.VecVecPoint? contours;
    cv.VecVec4i? hierarchy;
    final out = <List<Offset>>[];
    try {
      prob.data.setAll(0, map);
      (_, mask) = cv.threshold(prob, binThresh * 255, 255, cv.THRESH_BINARY);
      // Outer contours only (PaddleOCR uses RETR_LIST): a hole inside a text
      // blob would otherwise become a second, nested box and duplicate text.
      (contours, hierarchy) = cv.findContours(mask, cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE);
      for (var i = 0; i < contours.length && out.length < 1000; i++) {
        final c = contours[i];
        if (c.length < 4) continue;
        final rect = cv.minAreaRect(c);
        final box = _ordered(rect.points.toList().map((p) => Offset(p.x, p.y)).toList());
        rect.dispose();
        final w = (box[0] - box[1]).distance, h = (box[0] - box[3]).distance;
        if (math.min(w, h) < 3) continue;
        if (_boxScore(prob, box) < boxThresh) continue;
        final d = w * h * unclipRatio / (2 * (w + h));
        final grown = _grow(box, d);
        final gw = (grown[0] - grown[1]).distance, gh = (grown[0] - grown[3]).distance;
        if (math.min(gw, gh) < 5) continue;
        out.add(grown);
      }
    } finally {
      contours?.dispose();
      hierarchy?.dispose();
      mask?.dispose();
      prob.dispose();
    }
    return out;
  }

  /// Mean probability inside [box].
  static double _boxScore(cv.Mat prob, List<Offset> box) {
    final x0 = box.map((p) => p.dx).reduce(math.min).floor().clamp(0, prob.cols - 1);
    final y0 = box.map((p) => p.dy).reduce(math.min).floor().clamp(0, prob.rows - 1);
    final x1 = box.map((p) => p.dx).reduce(math.max).ceil().clamp(0, prob.cols - 1);
    final y1 = box.map((p) => p.dy).reduce(math.max).ceil().clamp(0, prob.rows - 1);
    final roi = prob.region(cv.Rect(x0, y0, x1 - x0 + 1, y1 - y0 + 1));
    final m = cv.Mat.zeros(y1 - y0 + 1, x1 - x0 + 1, cv.MatType.CV_8UC1);
    final pts = cv.VecVecPoint.fromList([
      [for (final p in box) cv.Point((p.dx - x0).round(), (p.dy - y0).round())],
    ]);
    try {
      cv.fillPoly(m, pts, cv.Scalar(1, 0, 0, 0));
      return cv.mean(roi, mask: m).val1 / 255;
    } finally {
      pts.dispose();
      m.dispose();
      roi.dispose();
    }
  }

  /// Moves every corner of a rectangle outward by [d] along both edges.
  static List<Offset> _grow(List<Offset> b, double d) {
    Offset unit(Offset v) => v.distance == 0 ? Offset.zero : v / v.distance;
    final u = unit(b[1] - b[0]) * d, v = unit(b[3] - b[0]) * d;
    return [b[0] - u - v, b[1] + u - v, b[2] + u + v, b[3] - u + v];
  }

  /// Orders four rectangle corners tl, tr, br, bl (the two leftmost are the
  /// left edge; within each edge the upper one comes first).
  static List<Offset> _ordered(List<Offset> pts) {
    final byX = [...pts]..sort((a, b) => a.dx.compareTo(b.dx));
    final left = [byX[0], byX[1]]..sort((a, b) => a.dy.compareTo(b.dy));
    final right = [byX[2], byX[3]]..sort((a, b) => a.dy.compareTo(b.dy));
    return [left[0], right[0], right[1], left[1]];
  }

  static List<Offset> _clampBox(List<Offset> box, int w, int h) =>
      [for (final p in box) Offset(p.dx.clamp(0, w - 1).toDouble(), p.dy.clamp(0, h - 1).toDouble())];

  // ----------------------------------------------------------- recognition

  Future<List<OcrLine>> _recognize(cv.Mat src, List<List<Offset>> boxes) async {
    if (boxes.isEmpty) return const [];
    final crops = <cv.Mat>[];
    try {
      for (final b in boxes) {
        crops.add(cropLine(src, b));
      }
      await _fixOrientation(crops);
      // Batch crops of similar shape together so little width is padding.
      final order = List.generate(crops.length, (i) => i)
        ..sort((a, b) => (crops[a].cols / crops[a].rows).compareTo(crops[b].cols / crops[b].rows));
      final texts = List<(String, double)>.filled(crops.length, ('', 0));
      for (var s = 0; s < order.length; s += recBatch) {
        final idx = order.sublist(s, math.min(s + recBatch, order.length));
        final batch = [for (final i in idx) crops[i]];
        final decoded = await _recBatch(batch);
        for (var k = 0; k < idx.length; k++) {
          texts[idx[k]] = decoded[k];
        }
      }
      return [
        for (var i = 0; i < boxes.length; i++)
          if (texts[i].$1.trim().isNotEmpty && texts[i].$2 >= minTextScore) OcrLine(boxes[i], texts[i].$1, texts[i].$2),
      ];
    } finally {
      for (final c in crops) {
        c.dispose();
      }
    }
  }

  /// Straightens the text under [box] into an upright strip. Tall strips
  /// (vertical text) are turned 90 degrees counter-clockwise.
  static cv.Mat cropLine(cv.Mat src, List<Offset> box) {
    final w = math.max((box[0] - box[1]).distance, (box[3] - box[2]).distance).round().clamp(1, 1 << 14);
    final h = math.max((box[0] - box[3]).distance, (box[1] - box[2]).distance).round().clamp(1, 1 << 14);
    final from = cv.VecPoint2f.fromList([for (final p in box) cv.Point2f(p.dx, p.dy)]);
    final to = cv.VecPoint2f.fromList([
      cv.Point2f(0, 0),
      cv.Point2f(w.toDouble(), 0),
      cv.Point2f(w.toDouble(), h.toDouble()),
      cv.Point2f(0, h.toDouble()),
    ]);
    final m = cv.getPerspectiveTransform2f(from, to);
    try {
      final out = cv.warpPerspective(src, m, (w, h), flags: cv.INTER_CUBIC, borderMode: cv.BORDER_REPLICATE);
      if (h / w >= 1.5) {
        final r = cv.rotate(out, cv.ROTATE_90_COUNTERCLOCKWISE);
        out.dispose();
        return r;
      }
      return out;
    } finally {
      m.dispose();
      from.dispose();
      to.dispose();
    }
  }

  /// Flips crops the classifier is confident are upside down.
  Future<void> _fixOrientation(List<cv.Mat> crops) async {
    for (var s = 0; s < crops.length; s += clsBatch) {
      final n = math.min(clsBatch, crops.length - s);
      final buf = Uint8List(n * clsHeight * clsWidth * 3);
      for (var k = 0; k < n; k++) {
        final r = cv.resize(crops[s + k], (clsWidth, clsHeight), interpolation: cv.INTER_LINEAR);
        buf.setRange(k * clsHeight * clsWidth * 3, (k + 1) * clsHeight * clsWidth * 3, _packed(r));
        r.dispose();
      }
      final p = await backend.orientation(buf, n);
      for (var k = 0; k < n; k++) {
        if (p[k * 2 + 1] > clsThresh) {
          final flipped = cv.rotate(crops[s + k], cv.ROTATE_180);
          crops[s + k].dispose();
          crops[s + k] = flipped;
        }
      }
    }
  }

  static int recWidth(cv.Mat crop) =>
      (recHeight * crop.cols / crop.rows).ceil().clamp(recHeight ~/ 4, recMaxWidth);

  Future<List<(String, double)>> _recBatch(List<cv.Mat> batch) async {
    final widths = [for (final c in batch) recWidth(c)];
    final width = widths.reduce(math.max);
    final rowBytes = width * 3;
    final img = recHeight * rowBytes;
    // 128 is what the in-graph normalisation maps to ~0, matching the zero
    // padding PaddleOCR uses after normalising.
    final buf = Uint8List(batch.length * img)..fillRange(0, batch.length * img, 128);
    for (var k = 0; k < batch.length; k++) {
      final r = cv.resize(batch[k], (widths[k], recHeight), interpolation: cv.INTER_LINEAR);
      final data = _packed(r);
      final w3 = widths[k] * 3;
      for (var y = 0; y < recHeight; y++) {
        buf.setRange(k * img + y * rowBytes, k * img + y * rowBytes + w3, data, y * w3);
      }
      r.dispose();
    }
    final out = await backend.recognize(buf, batch.length, width);
    return [for (var k = 0; k < batch.length; k++) ctcDecode(out, k, keys)];
  }

  /// Greedy CTC: collapse repeats, drop blanks. Score is the mean
  /// probability of the kept characters.
  static (String, double) ctcDecode(RecOutput out, int item, List<String> keys) {
    final sb = StringBuffer();
    var last = 0, sum = 0.0, count = 0;
    final base = item * out.steps;
    for (var t = 0; t < out.steps; t++) {
      final i = out.index[base + t];
      if (i != 0 && i != last && i < keys.length) {
        sb.write(keys[i]);
        sum += out.prob[base + t];
        count++;
      }
      last = i;
    }
    return (sb.toString(), count == 0 ? 0.0 : sum / count);
  }

  /// Pixel bytes of a continuous 8-bit Mat, copied out of native memory.
  static Uint8List _packed(cv.Mat m) {
    final c = m.isContinuous ? m : m.clone();
    final bytes = Uint8List.fromList(c.data);
    if (!identical(c, m)) c.dispose();
    return bytes;
  }
}
