
import 'package:flutter_test/flutter_test.dart';
import 'package:doc_scanner/scan/quad.dart';

void main() {
  test('ordered sorts arbitrary corners into tl, tr, br, bl', () {
    final q = Quad.ordered(const [Offset(90, 110), Offset(10, 5), Offset(5, 100), Offset(95, 8)]);
    expect(q.tl, const Offset(10, 5));
    expect(q.tr, const Offset(95, 8));
    expect(q.br, const Offset(90, 110));
    expect(q.bl, const Offset(5, 100));
  });

  test('targetSize uses the longer of opposite edges', () {
    const q = Quad(Offset(0, 0), Offset(100, 0), Offset(120, 200), Offset(0, 200));
    final (w, h) = q.targetSize();
    expect(w, 120);
    expect(h, 201); // right edge: hypot(20, 200) = 200.99
  });

  test('isConvex rejects a self-intersecting (bow-tie) quad', () {
    expect(Quad.fullImage(100, 50).isConvex, isTrue);
    const bowTie = Quad(Offset(0, 0), Offset(100, 100), Offset(100, 0), Offset(0, 100));
    expect(bowTie.isConvex, isFalse);
  });

  test('area of a full-image quad is w*h', () {
    expect(Quad.fullImage(30, 40).area, 1200);
  });

  test('JSON round trip keeps all corners', () {
    const q = Quad(Offset(1.5, 2), Offset(3, 4), Offset(5, 6.25), Offset(7, 8));
    final back = Quad.fromJson(q.toJson());
    expect(back.points, q.points);
  });

  test('scale and clamp', () {
    final q = Quad.fullImage(100, 100).scale(0.5, 2);
    expect(q.br, const Offset(50, 200));
    expect(q.clamp(40, 150).br, const Offset(40, 150));
  });
}
