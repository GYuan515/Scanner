import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:doc_scanner/data/exporter.dart';
import 'package:doc_scanner/scan/image_ops.dart';
import 'package:doc_scanner/scan/quad.dart';
import 'package:doc_scanner/scan/stability.dart';

Uint8List jpeg(int w, int h, int gray) {
  final m = cv.Mat.fromScalar(h, w, cv.MatType.CV_8UC3, cv.Scalar.all(gray.toDouble()));
  final (_, b) = cv.imencode('.jpg', m);
  m.dispose();
  return b;
}

(int, int) sizeOf(Uint8List bytes) {
  final m = cv.imdecode(bytes, cv.IMREAD_COLOR);
  final s = (m.cols, m.rows);
  m.dispose();
  return s;
}

void main() {
  group('StabilityTracker', () {
    const frame = Size(1000, 800);
    final page = Quad(const Offset(100, 100), const Offset(900, 100), const Offset(900, 700), const Offset(100, 700));
    Quad shifted(double dx) => Quad(page.tl.translate(dx, 0), page.tr.translate(dx, 0), page.br.translate(dx, 0), page.bl.translate(dx, 0));

    test('fires once after the outline holds still, then waits for the page to change', () {
      final t = StabilityTracker(frames: 4);
      final fired = [for (var i = 0; i < 10; i++) t.update(page, frame)];
      expect(fired.where((f) => f).length, 1);
      expect(fired.indexOf(true), 3); // the 4th identical frame
    });

    test('jitter within tolerance still counts as still', () {
      final t = StabilityTracker(frames: 3);
      var fired = false;
      for (var i = 0; i < 6; i++) {
        fired |= t.update(shifted(i.isEven ? 0 : 5), frame);
      }
      expect(fired, isTrue);
    });

    test('movement resets the count', () {
      final t = StabilityTracker(frames: 3);
      var fired = false;
      for (var i = 0; i < 10; i++) {
        fired |= t.update(shifted(i * 40.0), frame);
      }
      expect(fired, isFalse);
    });

    test('a small outline never fires', () {
      final t = StabilityTracker(frames: 2);
      final tiny = Quad(const Offset(0, 0), const Offset(50, 0), const Offset(50, 50), const Offset(0, 50));
      expect([for (var i = 0; i < 6; i++) t.update(tiny, frame)], everyElement(isFalse));
    });

    test('re-arms after the page leaves the frame', () {
      final t = StabilityTracker(frames: 2);
      var shots = 0;
      for (var i = 0; i < 5; i++) {
        if (t.update(page, frame)) shots++;
      }
      t.update(null, frame);
      for (var i = 0; i < 5; i++) {
        if (t.update(page, frame)) shots++;
      }
      expect(shots, 2);
    });
  });

  test('new filters produce an image of the same size', () {
    final src = cv.imdecode(jpeg(320, 240, 128), cv.IMREAD_COLOR);
    for (final f in [ScanFilter.sharpen, ScanFilter.brighten]) {
      final out = ImageOps.applyFilter(src, f);
      expect((out.cols, out.rows, out.channels), (320, 240, 3), reason: f.name);
      out.dispose();
    }
    src.dispose();
  });

  test('brighten raises mid-tones', () {
    final src = cv.imdecode(jpeg(64, 64, 100), cv.IMREAD_COLOR);
    final out = ImageOps.applyFilter(src, ScanFilter.brighten);
    expect(cv.mean(out).val1, greaterThan(cv.mean(src).val1 + 10));
    src.dispose();
    out.dispose();
  });

  group('stitchVertical', () {
    test('scales pages to a common width and adds gaps', () {
      final out = ImageOps.stitchVertical([jpeg(800, 1000, 200), jpeg(400, 400, 100)], gap: 20);
      // second page is upscaled to 800 wide -> 800 tall
      expect(sizeOf(out), (800, 1000 + 20 + 800));
    });

    test('caps width', () {
      final out = ImageOps.stitchVertical([jpeg(3000, 1000, 200)], maxWidth: 1500);
      expect(sizeOf(out), (1500, 500));
    });

    test('shrinks to stay under the height limit', () {
      final out = ImageOps.stitchVertical([for (var i = 0; i < 5; i++) jpeg(1000, 3000, 200)], gap: 0, maxHeight: 6000);
      final (w, h) = sizeOf(out);
      expect(h, lessThanOrEqualTo(6000));
      expect(w, 400);
    });

    test('rejects an empty list', () {
      expect(() => ImageOps.stitchVertical([]), throwsArgumentError);
    });
  });

  test('bgraToJpeg converts rendered PDF pixels', () {
    final bgra = Uint8List(40 * 30 * 4)..fillRange(0, 40 * 30 * 4, 255);
    expect(sizeOf(ImageOps.bgraToJpeg(bgra, 40, 30)), (40, 30));
  });

  group('PDF export', () {
    test('one page per image, valid PDF header', () async {
      final bytes = await Exporter.pdfBytes([PdfPageInput(jpeg(600, 800, 200)), PdfPageInput(jpeg(800, 600, 200))], const PdfOptions());
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      expect(RegExp(r'/Type\s*/Page[^s]').allMatches(String.fromCharCodes(bytes)).length, 2);
    });

    test('original-size pages grow by the margin', () async {
      Future<String> box(PdfMargin m) async =>
          RegExp(r'/MediaBox\s*\[([^\]]+)\]').firstMatch(String.fromCharCodes(
              await Exporter.pdfBytes([PdfPageInput(jpeg(300, 300, 200))], PdfOptions(size: PdfPageSize.fit, margin: m))))!.group(1)!.trim();
      expect(await box(PdfMargin.none), '0 0 144 144'); // 300 px at 150 dpi = 2 in
      expect(await box(PdfMargin.normal), '0 0 216 216');
    });
  });
}
