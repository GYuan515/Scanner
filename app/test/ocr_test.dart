import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:doc_scanner/ocr/ocr_pipeline.dart';
import 'package:doc_scanner/ocr/ocr_result.dart';

/// Stand-in for the ONNX models.
///
/// detect: dark pixels smeared sideways into line-shaped blobs, which is
/// roughly what the real probability map looks like for printed text.
/// recognize: every crop reads as keys[1..3] ("ABC"), with repeats and
/// blanks so the CTC collapse is exercised.
class FakeBackend implements OcrBackend {
  final detSizes = <(int, int)>[];
  final recWidths = <int>[];
  var flip = false;

  @override
  Future<Uint8List> detect(Uint8List bgr, int height, int width) async {
    detSizes.add((width, height));
    final img = cv.Mat.create(rows: height, cols: width, type: cv.MatType.CV_8UC3);
    img.data.setAll(0, bgr);
    final gray = cv.cvtColor(img, cv.COLOR_BGR2GRAY);
    final (_, ink) = cv.threshold(gray, 128, 255, cv.THRESH_BINARY_INV);
    // Scaled with the input so glyphs merge into one blob per line.
    final k = cv.getStructuringElement(cv.MORPH_RECT, ((width / 40).round(), (height / 200).round().clamp(3, 15)));
    final blobs = cv.dilate(ink, k);
    final out = Uint8List.fromList(blobs.data);
    for (final m in [img, gray, ink, k, blobs]) {
      m.dispose();
    }
    return out;
  }

  @override
  Future<Float32List> orientation(Uint8List bgr, int n) async =>
      Float32List.fromList([for (var i = 0; i < n; i++) ...(flip ? [0.02, 0.98] : [0.98, 0.02])]);

  @override
  Future<RecOutput> recognize(Uint8List bgr, int n, int width) async {
    expect(bgr.length, n * OcrPipeline.recHeight * width * 3);
    recWidths.add(width);
    const seq = [0, 1, 1, 0, 2, 2, 2, 0, 0, 3];
    return RecOutput(
      Int32List.fromList([for (var i = 0; i < n; i++) ...seq]),
      Float32List.fromList([for (var i = 0; i < n * seq.length; i++) 0.9]),
      seq.length,
    );
  }
}

final keys = OcrPipeline.keysFrom('A\nB\nC');

void main() {
  test('detector input: multiples of 32, long side capped, small images enlarged', () {
    expect(OcrPipeline.detSize(2480, 3508, 1600), (1120, 1600));
    final (w, h) = OcrPipeline.detSize(300, 80, 1600);
    expect(w % 32, 0);
    expect(h % 32, 0);
    expect(w, 1600); // enlarged towards 736 on the short side, capped by the long side
    expect(OcrPipeline.detSize(10, 10, 1600), (736, 736));
  });

  test('boxesFromMap finds blobs and grows them by the unclip distance', () {
    const w = 320, h = 160;
    final map = Uint8List(w * h);
    void fill(int x0, int y0, int x1, int y1) {
      for (var y = y0; y < y1; y++) {
        map.fillRange(y * w + x0, y * w + x1, 230);
      }
    }

    fill(20, 20, 220, 40); // 200 x 20
    fill(40, 100, 140, 130); // 100 x 30
    final boxes = OcrPipeline.boxesFromMap(map, w, h)..sort((a, b) => a[0].dy.compareTo(b[0].dy));
    expect(boxes, hasLength(2));
    // 200x20 blob (contour spans 199x19): d = 199*19*1.6/(2*218) ~ 13.9
    final b = boxes.first;
    expect(b[0].dx, closeTo(20 - 13.9, 1.5));
    expect(b[0].dy, closeTo(20 - 13.9, 1.5));
    expect(b[2].dx, closeTo(219 + 13.9, 1.5));
    expect(b[2].dy, closeTo(39 + 13.9, 1.5));
    // tl, tr, br, bl
    expect(b[1].dx, greaterThan(b[0].dx));
    expect(b[3].dy, greaterThan(b[0].dy));
  });

  test('boxesFromMap ignores faint and tiny blobs', () {
    const w = 200, h = 100;
    final map = Uint8List(w * h);
    for (var y = 10; y < 30; y++) {
      map.fillRange(y * w + 10, y * w + 150, 100); // above 0.3 but mean < 0.5
    }
    for (var y = 60; y < 62; y++) {
      map.fillRange(y * w + 10, y * w + 150, 250); // 2 px tall
    }
    expect(OcrPipeline.boxesFromMap(map, w, h), isEmpty);
  });

  test('ctcDecode collapses repeats, drops blanks, averages kept probabilities', () {
    final out = RecOutput(
      Int32List.fromList([1, 1, 0, 1, 2, 4, 4, 0, 1, 1]),
      Float32List.fromList([0.9, 0.8, 1, 0.7, 0.6, 0.5, 0.5, 1, 0.4, 0.4]),
      5,
    );
    final (a, sa) = OcrPipeline.ctcDecode(out, 0, keys);
    expect(a, 'AAB');
    expect(sa, closeTo((0.9 + 0.7 + 0.6) / 3, 1e-6));
    final (b, _) = OcrPipeline.ctcDecode(out, 1, keys);
    expect(b, ' A'); // index 4 is the trailing space key
  });

  test('arrange groups side-by-side boxes into one row, left to right', () {
    OcrLine box(double x, double y, double w, double h, String t) =>
        OcrLine([Offset(x, y), Offset(x + w, y), Offset(x + w, y + h), Offset(x, y + h)], t, 1);
    final rows = OcrResult.arrange([
      box(695, 1296, 120, 40, '数量3'),
      box(96, 1298, 120, 38, '第一项'),
      box(97, 636, 300, 30, '电话'),
      box(384, 634, 300, 34, '邮箱'),
      box(94, 128, 400, 70, '标题'),
    ]);
    expect(rows.map((r) => r.map((l) => l.text).toList()).toList(), [
      ['标题'],
      ['电话', '邮箱'],
      ['第一项', '数量3'],
    ]);
    expect(OcrResult(width: 1, height: 1, rows: rows).text, '标题\n电话 邮箱\n第一项 数量3');
  });

  test('OcrResult JSON round trip', () {
    final r = OcrResult(width: 100, height: 50, rows: [
      [
        const OcrLine([Offset(1, 2), Offset(30, 2), Offset(30, 12), Offset(1, 12)], '你好', 0.987),
        const OcrLine([Offset(40, 2), Offset(90, 3), Offset(90, 13), Offset(40, 12)], 'abc', 0.5),
      ],
    ]);
    final back = OcrResult.fromJsonString(r.toJsonString());
    expect(back.width, 100);
    expect(back.text, '你好 abc');
    expect(back.lines.last.box[1], const Offset(90, 3));
    expect(back.lines.first.score, closeTo(0.987, 1e-9));
  });

  test('cropLine straightens a box and turns tall strips upright', () {
    final img = cv.Mat.zeros(200, 300, cv.MatType.CV_8UC3);
    final wide = OcrPipeline.cropLine(img, const [Offset(10, 10), Offset(110, 10), Offset(110, 40), Offset(10, 40)]);
    expect((wide.cols, wide.rows), (100, 30));
    final tall = OcrPipeline.cropLine(img, const [Offset(10, 10), Offset(40, 10), Offset(40, 110), Offset(10, 110)]);
    expect((tall.cols, tall.rows), (100, 30));
    for (final m in [img, wide, tall]) {
      m.dispose();
    }
  });

  group('pipeline on a rendered page', () {
    late cv.Mat page;
    setUp(() => page = cv.imread('test/fixtures/ocr_page.jpg', flags: cv.IMREAD_COLOR));
    tearDown(() => page.dispose());

    test('finds every text line in reading order', () async {
      final backend = FakeBackend();
      final result = await OcrPipeline(backend, keys).run(page);
      expect(backend.detSizes.single, (1120, 1600));
      expect(result.width, page.cols);
      expect(result.height, page.rows);
      // 7 text lines plus the two-column row at the bottom.
      expect(result.rows.length, 8);
      expect(result.rows.last, hasLength(2));
      expect(result.rows.last.first.bounds.left, lessThan(result.rows.last.last.bounds.left));
      for (var i = 1; i < result.rows.length; i++) {
        expect(result.rows[i].first.bounds.top, greaterThan(result.rows[i - 1].first.bounds.top));
      }
      for (final l in result.lines) {
        expect(l.text, 'ABC');
        expect(l.score, closeTo(0.9, 1e-6));
        for (final p in l.box) {
          expect(p.dx, inInclusiveRange(0, page.cols - 1));
          expect(p.dy, inInclusiveRange(0, page.rows - 1));
        }
      }
      // The title (first line, 64 px font drawn at y=120) maps back to page
      // pixels. The fake map is not shrunk like a real DB map, so after the
      // unclip the box is larger than the glyphs; it must still contain them.
      final title = result.rows.first.first.bounds;
      expect(title.top, inInclusiveRange(60, 130));
      expect(title.left, inInclusiveRange(20, 100));
      expect(title.bottom, greaterThan(180));
      expect(title.right, greaterThan(500));
      // Batches are capped and padded to the widest crop.
      expect(backend.recWidths.length, (result.lines.length / OcrPipeline.recBatch).ceil());
    });

    test('region reads only that area and keeps page coordinates', () async {
      final result = await OcrPipeline(FakeBackend(), keys).run(page, region: cv.Rect(600, 1250, 500, 120));
      expect(result.rows, hasLength(1));
      for (final l in result.lines) {
        final b = l.bounds;
        expect(b.left, greaterThanOrEqualTo(600));
        expect(b.top, greaterThanOrEqualTo(1250));
        expect(b.right, lessThanOrEqualTo(1100));
        expect(b.bottom, lessThanOrEqualTo(1370));
      }
      expect(result.width, page.cols);
    });

    test('blank region falls back to reading the whole selection', () async {
      final result = await OcrPipeline(FakeBackend(), keys).run(page, region: cv.Rect(900, 900, 200, 60));
      expect(result.lines.single.bounds, const Rect.fromLTRB(900, 900, 1100, 960));
    });
  });

  test('fixture exists', () => expect(File('test/fixtures/ocr_page.jpg').existsSync(), isTrue));
}
