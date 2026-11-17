import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

/// One detected text box and what was read from it.
class OcrLine {
  const OcrLine(this.box, this.text, this.score);

  /// Corners in image pixels: top-left, top-right, bottom-right,
  /// bottom-left of the text as it reads.
  final List<Offset> box;
  final String text;

  /// Mean character confidence, 0..1.
  final double score;

  Rect get bounds {
    var l = double.infinity, t = double.infinity, r = -double.infinity, b = -double.infinity;
    for (final p in box) {
      l = math.min(l, p.dx);
      t = math.min(t, p.dy);
      r = math.max(r, p.dx);
      b = math.max(b, p.dy);
    }
    return Rect.fromLTRB(l, t, r, b);
  }

  /// Text height along the box's short side, in pixels.
  double get height => math.min((box[0] - box[3]).distance, (box[1] - box[2]).distance);

  Map<String, dynamic> toJson() => {
        'b': [for (final p in box) ...[_r(p.dx), _r(p.dy)]],
        't': text,
        's': _r(score * 1000) / 1000,
      };

  factory OcrLine.fromJson(Map<String, dynamic> j) {
    final b = (j['b'] as List).cast<num>();
    return OcrLine(
      [for (var i = 0; i < 8; i += 2) Offset(b[i].toDouble(), b[i + 1].toDouble())],
      j['t'] as String,
      (j['s'] as num).toDouble(),
    );
  }

  static double _r(double v) => (v * 10).roundToDouble() / 10;
}

/// OCR output for one image: the lines in reading order, grouped into rows.
class OcrResult {
  const OcrResult({required this.width, required this.height, required this.rows});

  /// Size of the image the coordinates refer to.
  final int width;
  final int height;

  /// Rows top to bottom; each row's boxes left to right.
  final List<List<OcrLine>> rows;

  static const empty = OcrResult(width: 0, height: 0, rows: []);

  Iterable<OcrLine> get lines => rows.expand((r) => r);

  bool get isEmpty => rows.isEmpty;

  /// Plain text: one row per line, boxes on the same row separated by a space.
  String get text => rows.map((r) => r.map((l) => l.text).join(' ')).join('\n');

  String toJsonString() => jsonEncode({
        'w': width,
        'h': height,
        'rows': [for (final r in rows) [for (final l in r) l.toJson()]],
      });

  factory OcrResult.fromJsonString(String s) {
    final j = jsonDecode(s) as Map<String, dynamic>;
    return OcrResult(
      width: j['w'] as int,
      height: j['h'] as int,
      rows: [
        for (final r in j['rows'] as List) [for (final l in r as List) OcrLine.fromJson(l as Map<String, dynamic>)],
      ],
    );
  }

  /// Groups [lines] into rows and sorts them into reading order.
  ///
  /// A box joins a row when its vertical extent overlaps the row's by more
  /// than half of the smaller height, so slightly skewed lines and boxes of
  /// different font sizes on one line still end up together.
  static List<List<OcrLine>> arrange(List<OcrLine> lines) {
    final sorted = [...lines]..sort((a, b) => a.bounds.center.dy.compareTo(b.bounds.center.dy));
    final rows = <List<OcrLine>>[];
    final spans = <(double, double)>[];
    for (final l in sorted) {
      final b = l.bounds;
      var placed = false;
      for (var i = rows.length - 1; i >= 0 && i >= rows.length - 3; i--) {
        final (top, bottom) = spans[i];
        final overlap = math.min(bottom, b.bottom) - math.max(top, b.top);
        if (overlap > 0.5 * math.min(bottom - top, b.height)) {
          rows[i].add(l);
          spans[i] = (math.min(top, b.top), math.max(bottom, b.bottom));
          placed = true;
          break;
        }
      }
      if (!placed) {
        rows.add([l]);
        spans.add((b.top, b.bottom));
      }
    }
    for (final r in rows) {
      r.sort((a, b) => a.bounds.left.compareTo(b.bounds.left));
    }
    return rows;
  }
}
