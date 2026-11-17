import 'dart:math' as math;
import 'dart:ui' show Offset;

/// Four document corners in image pixel coordinates, ordered
/// top-left, top-right, bottom-right, bottom-left.
class Quad {
  const Quad(this.tl, this.tr, this.br, this.bl);

  final Offset tl;
  final Offset tr;
  final Offset br;
  final Offset bl;

  List<Offset> get points => [tl, tr, br, bl];

  factory Quad.fullImage(double w, double h) =>
      Quad(Offset.zero, Offset(w, 0), Offset(w, h), Offset(0, h));

  /// Orders four arbitrary points into tl, tr, br, bl.
  /// tl has the smallest x+y, br the largest; tr has the smallest y-x,
  /// bl the largest.
  factory Quad.ordered(List<Offset> pts) {
    assert(pts.length == 4);
    final bySum = [...pts]..sort((a, b) => (a.dx + a.dy).compareTo(b.dx + b.dy));
    final byDiff = [...pts]..sort((a, b) => (a.dy - a.dx).compareTo(b.dy - b.dx));
    return Quad(bySum.first, byDiff.first, bySum.last, byDiff.last);
  }

  Quad replace(int index, Offset p) {
    final list = points;
    list[index] = p;
    return Quad(list[0], list[1], list[2], list[3]);
  }

  Quad scale(double sx, double sy) => Quad(
        Offset(tl.dx * sx, tl.dy * sy),
        Offset(tr.dx * sx, tr.dy * sy),
        Offset(br.dx * sx, br.dy * sy),
        Offset(bl.dx * sx, bl.dy * sy),
      );

  Quad clamp(double w, double h) {
    Offset c(Offset p) => Offset(p.dx.clamp(0, w), p.dy.clamp(0, h));
    return Quad(c(tl), c(tr), c(br), c(bl));
  }

  /// Output size of the rectified page: the longer of each pair of
  /// opposite edges.
  (int, int) targetSize() {
    double d(Offset a, Offset b) => (a - b).distance;
    final w = math.max(d(tl, tr), d(bl, br));
    final h = math.max(d(tl, bl), d(tr, br));
    return (math.max(1, w.round()), math.max(1, h.round()));
  }

  /// True when the polygon is convex and not self-intersecting.
  bool get isConvex {
    final p = points;
    double? sign;
    for (var i = 0; i < 4; i++) {
      final a = p[i], b = p[(i + 1) % 4], c = p[(i + 2) % 4];
      final cross = (b.dx - a.dx) * (c.dy - b.dy) - (b.dy - a.dy) * (c.dx - b.dx);
      if (cross.abs() < 1e-9) continue;
      sign ??= cross.sign;
      if (cross.sign != sign) return false;
    }
    return true;
  }

  double get area {
    final p = points;
    var s = 0.0;
    for (var i = 0; i < 4; i++) {
      final a = p[i], b = p[(i + 1) % 4];
      s += a.dx * b.dy - b.dx * a.dy;
    }
    return s.abs() / 2;
  }

  Map<String, dynamic> toJson() => {
        'p': [for (final o in points) [o.dx, o.dy]],
      };

  factory Quad.fromJson(Map<String, dynamic> j) {
    final p = [for (final e in j['p'] as List) Offset((e[0] as num).toDouble(), (e[1] as num).toDouble())];
    return Quad(p[0], p[1], p[2], p[3]);
  }

  @override
  String toString() => 'Quad($tl, $tr, $br, $bl)';
}
