import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:doc_scanner/markup/geometry.dart';
import 'package:doc_scanner/markup/markup.dart';
import 'package:doc_scanner/markup/redact.dart';
import 'package:doc_scanner/markup/watermark.dart';
import 'package:doc_scanner/ocr/ocr_result.dart';
import 'package:doc_scanner/scan/image_ops.dart';
import 'package:doc_scanner/scan/quad.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;

void main() {
  const quad = Quad(Offset(100, 80), Offset(900, 120), Offset(880, 1250), Offset(60, 1200));

  group('PageGeometry', () {
    test('without a crop it is the identity, rotations turn the frame', () {
      final g = PageGeometry(originalWidth: 400, originalHeight: 300);
      expect(g.processedSize, const Size(400, 300));
      expect(g.toOriginal(const Offset(10, 20)), const Offset(10, 20));
      final r = PageGeometry(originalWidth: 400, originalHeight: 300, rotation: 1);
      expect(r.processedSize, const Size(300, 400));
      // Top-left of the photo ends up top-right after a clockwise turn.
      expect(r.fromOriginal(Offset.zero), const Offset(299, 0));
      for (final turns in [0, 1, 2, 3]) {
        final g2 = PageGeometry(originalWidth: 400, originalHeight: 300, rotation: turns);
        final p = g2.fromOriginal(const Offset(37, 211));
        expect(g2.toOriginal(p).dx, closeTo(37, 1e-9));
        expect(g2.toOriginal(p).dy, closeTo(211, 1e-9));
      }
    });

    test('crop corners map to the processed corners and back', () {
      final g = PageGeometry(originalWidth: 1000, originalHeight: 1300, quad: quad);
      final (w, h) = quad.targetSize();
      expect(g.processedSize, Size(w.toDouble(), h.toDouble()));
      final corners = [const Offset(0, 0), Offset(w - 1.0, 0), Offset(w - 1.0, h - 1.0), Offset(0, h - 1.0)];
      for (var i = 0; i < 4; i++) {
        final o = g.toOriginal(corners[i]);
        expect((o - quad.points[i]).distance, lessThan(1e-6));
        expect((g.fromOriginal(quad.points[i]) - corners[i]).distance, lessThan(1e-6));
      }
    });

    test('matches the OpenCV warp used to render the page', () {
      // Mark one photo pixel, warp with ImageOps, and find the mark.
      final img = cv.Mat.zeros(1300, 1000, cv.MatType.CV_8UC3);
      cv.circle(img, cv.Point(500, 640), 6, cv.Scalar(255, 255, 255), thickness: -1);
      final jpg = ImageOps.encodeJpeg(img);
      img.dispose();
      final out = ImageOps.process(jpg, quad: quad, filter: ScanFilter.original, rotateQuarterTurns: 1);
      final m = cv.imdecode(out, cv.IMREAD_GRAYSCALE);
      final (_, bin) = cv.threshold(m, 128, 255, cv.THRESH_BINARY);
      final mo = cv.moments(bin, binaryImage: true);
      final centre = Offset(mo.m10 / mo.m00, mo.m01 / mo.m00); // the dot's centroid
      final g = PageGeometry(originalWidth: 1000, originalHeight: 1300, quad: quad, rotation: 1);
      expect(Size(m.cols.toDouble(), m.rows.toDouble()), g.processedSize);
      final predicted = g.fromOriginal(const Offset(500, 640));
      expect((predicted - centre).distance, lessThan(1.5));
      m.dispose();
      bin.dispose();
    });

    test('jpegSize reads the header', () {
      final img = cv.Mat.zeros(123, 457, cv.MatType.CV_8UC3);
      expect(jpegSize(ImageOps.encodeJpeg(img)), (457, 123));
      img.dispose();
      expect(jpegSize(Uint8List.fromList([1, 2, 3])), isNull);
    });
  });

  group('markup', () {
    final items = PageMarkup([
      const MarkupItem(kind: MarkupKind.ink, points: [Offset(10, 10), Offset(50, 60), Offset(90, 20)], width: 4),
      const MarkupItem(kind: MarkupKind.highlight, rect: Rect.fromLTWH(100, 100, 300, 40), color: 0x66FFEB3B),
      const MarkupItem(kind: MarkupKind.text, rect: Rect.fromLTWH(200, 300, 240, 50), text: '已审核', width: 40),
      const MarkupItem(kind: MarkupKind.image, rect: Rect.fromLTWH(300, 500, 200, 80), angle: 0.3, image: 'sig1.png'),
      const MarkupItem(kind: MarkupKind.note, rect: Rect.fromLTWH(40, 600, 48, 48), text: '这里要改'),
    ]);

    test('JSON round trip', () {
      final back = PageMarkup.parse(items.toJsonString());
      expect(back.items.length, 5);
      expect(back.items[0].points[1], const Offset(50, 60));
      expect(back.items[1].rect, const Rect.fromLTWH(100, 100, 300, 40));
      expect(back.items[2].text, '已审核');
      expect(back.items[3].angle, 0.3);
      expect(back.items[3].image, 'sig1.png');
      expect(back.imageFiles, ['sig1.png']);
      expect(PageMarkup.empty.toJsonString(), isNull);
      expect(PageMarkup.parse(null).isEmpty, isTrue);
    });

    test('hit testing finds the topmost item, rotated boxes included', () {
      expect(items.hitTest(const Offset(50, 58), 4), 0); // on the stroke
      expect(items.hitTest(const Offset(60, 20), 2), -1); // inside the V, off the stroke
      expect(items.hitTest(const Offset(250, 120), 0), 1);
      expect(items.hitTest(const Offset(400, 540), 0), 3);
      // A corner of the unrotated box that rotation moved away.
      expect(items.items[3].hit(const Offset(302, 502), 0), isFalse);
    });

    test('rotating the page carries markup along with the words', () {
      final g0 = PageGeometry(originalWidth: 1000, originalHeight: 800);
      final g1 = PageGeometry(originalWidth: 1000, originalHeight: 800, rotation: 1);
      final moved = items.remapped(g0, g1);
      // Highlight box: was 300 wide x 40 tall, now 40 wide x 300 tall.
      final hl = moved.items[1].rect;
      expect(hl.width, closeTo(40, 1));
      expect(hl.height, closeTo(300, 1));
      expect(hl.left, closeTo(800 - 1 - 140, 1));
      // Signature turns with the page, keeping its own shape.
      expect(moved.items[3].angle, closeTo(0.3 + math.pi / 2, 1e-9));
      expect(moved.items[3].rect.width, closeTo(200, 1e-6));
      // Ink points map one by one.
      expect(moved.items[0].points.first, g0.remap(const Offset(10, 10), g1));
      // Same geometry: nothing changes.
      expect(identical(items.remapped(g0, PageGeometry(originalWidth: 1000, originalHeight: 800)), items), isTrue);
    });
  });

  group('redaction search', () {
    OcrLine line(String t, {double x = 100, double w = 600}) =>
        OcrLine([Offset(x, 100), Offset(x + w, 100), Offset(x + w, 140), Offset(x, 140)], t, 1);

    test('presets find phone, ID card, bank card and e-mail', () {
      final lines = [
        line('电话13812345678，备用 021-68881234'),
        line('身份证号：11010519491231002X'),
        line('卡号 6222 0212 3456 7890 123'),
        line('邮箱 zhang.san@example.com'),
        line('订单号 123456789012345678901'),
      ];
      expect(findInLines(lines, RedactPreset.phone.regex).map((m) => m.text), ['13812345678']);
      expect(findInLines(lines, RedactPreset.idCard.regex).map((m) => m.text), ['11010519491231002X']);
      expect(findInLines(lines, RedactPreset.bankCard.regex).map((m) => m.text), ['6222 0212 3456 7890 123']);
      expect(findInLines(lines, RedactPreset.email.regex).map((m) => m.text), ['zhang.san@example.com']);
    });

    test('the area covers only the matched part of the line', () {
      // 2 CJK chars (weight 2) + 11 digits (6.05): digits take the right part.
      final l = line('电话13812345678');
      final m = findInLines([l], RedactPreset.phone.regex).single;
      final share = 2 / (2 + 11 * 0.55);
      expect(m.area.left, closeTo(100 + 600 * share - 6, 1)); // 6 = padding
      expect(m.area.right, closeTo(706, 1));
      expect(m.area.top, lessThan(100));
      expect(m.area.bottom, greaterThan(140));
      expect(findKeyword([l], '  ').isEmpty, isTrue);
      expect(findKeyword([line('Hello World')], 'world').single.text, 'World');
    });
  });

  test('watermark JSON round trip and emptiness', () {
    const w = Watermark(text: '仅供内部使用', opacity: 0.3, angle: -45, tiled: false);
    final back = Watermark.parse(w.toJsonString())!;
    expect(back.text, '仅供内部使用');
    expect(back.opacity, 0.3);
    expect(back.angle, -45);
    expect(back.tiled, isFalse);
    expect(const Watermark().toJsonString(), isNull);
    expect(Watermark.parse(null), isNull);
  });
}
