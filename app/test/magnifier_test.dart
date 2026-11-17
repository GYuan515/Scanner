import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doc_scanner/ui/magnifier.dart';

void main() {
  const view = Size(400, 800);
  const inset = loupeRadius + 8;

  test('loupe sits in the corner farthest from the finger', () {
    expect(loupeCenter(view, const Offset(10, 10)), const Offset(400 - inset, 800 - inset));
    expect(loupeCenter(view, const Offset(390, 790)), const Offset(inset, inset));
    expect(loupeCenter(view, const Offset(390, 10)), const Offset(inset, 800 - inset));
    expect(loupeCenter(view, const Offset(10, 790)), const Offset(400 - inset, inset));
  });

  test('loupe stays inside the view', () {
    for (final p in [Offset.zero, const Offset(200, 400), const Offset(400, 800)]) {
      final c = loupeCenter(view, p);
      expect(c.dx, inInclusiveRange(loupeRadius, view.width - loupeRadius));
      expect(c.dy, inInclusiveRange(loupeRadius, view.height - loupeRadius));
    }
  });

  test('a view too small for the loupe centers it instead of going negative', () {
    final c = loupeCenter(const Size(60, 60), const Offset(30, 30));
    expect(c, const Offset(30, 30));
  });
}
