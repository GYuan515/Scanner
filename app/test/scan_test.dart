import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:doc_scanner/scan/edge_detector.dart';
import 'package:doc_scanner/scan/image_ops.dart';

/// A dark 1200x900 "desk" with a light, slightly skewed "page" on it.
const corners = [Offset(220, 130), Offset(960, 170), Offset(1000, 780), Offset(180, 740)];

Uint8List syntheticPhoto() {
  final img = cv.Mat.zeros(900, 1200, cv.MatType.CV_8UC3);
  img.setTo(cv.Scalar(60, 50, 40));
  final pts = cv.VecVecPoint.fromList([
    [for (final c in corners) cv.Point(c.dx.round(), c.dy.round())],
  ]);
  cv.fillPoly(img, pts, cv.Scalar(235, 235, 235));
  cv.putText(img, 'Hello scanner', cv.Point(350, 450), cv.FONT_HERSHEY_SIMPLEX, 2, cv.Scalar(20, 20, 20), thickness: 4);
  final (_, bytes) = cv.imencode('.jpg', img);
  img.dispose();
  return bytes;
}

void main() {
  test('detects the page outline within a few pixels', () {
    final q = EdgeDetector.detectBytes(syntheticPhoto());
    expect(q, isNotNull);
    for (var i = 0; i < 4; i++) {
      expect((q!.points[i] - corners[i]).distance, lessThan(12), reason: 'corner $i: ${q.points[i]}');
    }
  });

  test('returns null when there is no page', () {
    final blank = cv.Mat.zeros(600, 800, cv.MatType.CV_8UC3);
    final (_, bytes) = cv.imencode('.jpg', blank);
    blank.dispose();
    expect(EdgeDetector.detectBytes(bytes), isNull);
  });

  test('prepare + process produce a rectified page for every filter', () {
    final prepared = ImageOps.prepare(syntheticPhoto());
    expect((prepared.width, prepared.height), (1200, 900));
    expect(prepared.quad, isNotNull);
    final (tw, th) = prepared.quad!.targetSize();
    for (final f in ScanFilter.values) {
      final out = cv.imdecode(ImageOps.process(prepared.bytes, quad: prepared.quad, filter: f), cv.IMREAD_COLOR);
      expect((out.cols, out.rows), (tw, th), reason: f.name);
      out.dispose();
    }
    final rotated = cv.imdecode(ImageOps.process(prepared.bytes, quad: prepared.quad, rotateQuarterTurns: 1), cv.IMREAD_COLOR);
    expect((rotated.cols, rotated.rows), (th, tw));
    rotated.dispose();
  });

  test('process rejects bytes that are not an image', () {
    expect(() => ImageOps.process(Uint8List.fromList([1, 2, 3])), throwsA(anything));
  });
}
