import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Rect;

/// Region types of the CDLA layout model, in its label order.
enum RegionKind {
  text,
  title,
  figure,
  figureCaption,
  table,
  tableCaption,
  header,
  footer,
  reference,
  equation;

  static RegionKind fromLabel(String l) => switch (l) {
        'title' => title,
        'figure' => figure,
        'figure_caption' => figureCaption,
        'table' => table,
        'table_caption' => tableCaption,
        'header' => header,
        'footer' => footer,
        'reference' => reference,
        'equation' => equation,
        _ => text,
      };
}

class LayoutRegion {
  const LayoutRegion(this.kind, this.box, this.score);
  final RegionKind kind;

  /// Page-image pixels.
  final Rect box;
  final double score;

  Map<String, dynamic> toJson() => {'k': kind.name, 'b': [box.left, box.top, box.right, box.bottom], 's': score};

  factory LayoutRegion.fromJson(Map<String, dynamic> j) {
    final b = (j['b'] as List).cast<num>();
    return LayoutRegion(
      RegionKind.values.byName(j['k'] as String),
      Rect.fromLTRB(b[0].toDouble(), b[1].toDouble(), b[2].toDouble(), b[3].toDouble()),
      (j['s'] as num).toDouble(),
    );
  }

  @override
  String toString() => '$kind $box ${score.toStringAsFixed(2)}';
}

/// PicoDet post-processing for the PP-Structure CDLA layout model
/// (mirrors RapidLayout): GFL box distributions at strides 8..64, top-1000
/// per stride, per-class score threshold and hard NMS.
class LayoutDecoder {
  static const inputW = 608, inputH = 800;
  static const strides = [8, 16, 32, 64];

  /// [scores] / [boxes]: per stride (8, 16, 32, 64), as the model outputs
  /// score8.. and box8..: N x classes and N x 4*(regMax+1).
  static List<LayoutRegion> decode(
    List<Float32List> scores,
    List<Float32List> boxes,
    int classes,
    int imageWidth,
    int imageHeight, {
    double conf = 0.5,
    double iou = 0.5,
  }) {
    final cand = <(Rect, Float32List)>[];
    for (var s = 0; s < strides.length; s++) {
      final stride = strides[s];
      final fw = (inputW / stride).ceil(), fh = (inputH / stride).ceil();
      final n = fw * fh;
      final sc = scores[s], bx = boxes[s];
      final bins = bx.length ~/ (n * 4); // regMax + 1
      // Top 1000 locations by best class score.
      final order = List<int>.generate(n, (i) => i);
      double best(int i) {
        var m = 0.0;
        for (var c = 0; c < classes; c++) {
          m = math.max(m, sc[i * classes + c]);
        }
        return m;
      }

      final bestScore = [for (var i = 0; i < n; i++) best(i)];
      order.sort((a, b) => bestScore[b].compareTo(bestScore[a]));
      for (final i in order.take(1000)) {
        if (bestScore[i] <= conf) break; // the rest cannot pass any class threshold
        final cx = (i % fw + 0.5) * stride, cy = (i ~/ fw + 0.5) * stride;
        final d = List<double>.filled(4, 0);
        for (var side = 0; side < 4; side++) {
          final off = (i * 4 + side) * bins;
          var mx = -double.infinity;
          for (var k = 0; k < bins; k++) {
            mx = math.max(mx, bx[off + k]);
          }
          var sum = 0.0, acc = 0.0;
          for (var k = 0; k < bins; k++) {
            final e = math.exp(bx[off + k] - mx);
            sum += e;
            acc += e * k;
          }
          d[side] = acc / sum * stride;
        }
        cand.add((
          Rect.fromLTRB(cx - d[0], cy - d[1], cx + d[2], cy + d[3]),
          Float32List.sublistView(sc, i * classes, (i + 1) * classes),
        ));
      }
    }

    final sx = imageWidth / inputW, sy = imageHeight / inputH;
    final out = <LayoutRegion>[];
    for (var c = 0; c < classes; c++) {
      final hits = [for (final (r, s) in cand) if (s[c] > conf) (r, s[c].toDouble())]
        ..sort((a, b) => b.$2.compareTo(a.$2));
      final keep = <(Rect, double)>[];
      for (final h in hits) {
        if (keep.length >= 100) break;
        if (keep.every((k) => _iou(k.$1, h.$1) <= iou)) keep.add(h);
      }
      for (final (r, s) in keep) {
        final clipped = Rect.fromLTRB(
          r.left.clamp(0, inputW) * sx,
          r.top.clamp(0, inputH) * sy,
          r.right.clamp(0, inputW) * sx,
          r.bottom.clamp(0, inputH) * sy,
        );
        out.add(LayoutRegion(RegionKind.values[c], clipped, s));
      }
    }
    return out;
  }

  static double _iou(Rect a, Rect b) {
    final i = a.intersect(b);
    if (i.width <= 0 || i.height <= 0) return 0;
    final inter = i.width * i.height;
    return inter / (a.width * a.height + b.width * b.height - inter + 1e-5);
  }
}
