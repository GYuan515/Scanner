import 'package:flutter_test/flutter_test.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:doc_scanner/markup/signature_extract.dart';
import 'package:doc_scanner/scan/image_ops.dart';

void main() {
  /// Paper lit unevenly (230 on the left, 170 on the right) with a blue
  /// scribble in the middle.
  cv.Mat photo() {
    final m = cv.Mat.zeros(400, 800, cv.MatType.CV_8UC3);
    for (var x = 0; x < 800; x += 10) {
      final v = 230 - 60 * x / 800;
      cv.rectangle(m, cv.Rect(x, 0, 10, 400), cv.Scalar(v, v, v), thickness: -1);
    }
    cv.line(m, cv.Point(250, 200), cv.Point(550, 150), cv.Scalar(160, 40, 10), thickness: 8);
    cv.line(m, cv.Point(300, 260), cv.Point(520, 230), cv.Scalar(160, 40, 10), thickness: 8);
    return m;
  }

  test('paper becomes transparent, ink stays, result is trimmed', () {
    final src = photo();
    final png = extractSignature(ImageOps.encodeJpeg(src, quality: 95));
    src.dispose();
    final out = cv.imdecode(png, cv.IMREAD_UNCHANGED);
    expect(out.channels, 4);
    // Trimmed to roughly the strokes (300 x 120 plus margins).
    expect(out.cols, inInclusiveRange(300, 360));
    expect(out.rows, inInclusiveRange(110, 160));
    final ch = cv.split(out);
    final alpha = ch[3];
    // Corners are paper: transparent, also on the darker right side.
    expect(alpha.at<int>(0, 0), 0);
    expect(alpha.at<int>(out.rows - 1, out.cols - 1), 0);
    // Some pixels are fully opaque ink, and they are blue.
    final (_, maxVal, _, loc) = cv.minMaxLoc(alpha);
    expect(maxVal, 255);
    final px = out.atPixel(loc.y, loc.x);
    expect(px[0], greaterThan(px[2] + 60)); // B >> R
    ch.dispose();
    out.dispose();
  });

  test('fixed colour and crop', () {
    final src = photo();
    final png = extractSignature(ImageOps.encodeJpeg(src, quality: 95), crop: (240, 120, 340, 100), color: InkColor.red);
    src.dispose();
    final out = cv.imdecode(png, cv.IMREAD_UNCHANGED);
    expect(out.cols, lessThanOrEqualTo(340));
    final ch = cv.split(out);
    final (_, _, _, loc) = cv.minMaxLoc(ch[3]);
    final px = out.atPixel(loc.y, loc.x);
    expect(px[2], greaterThan(150)); // red
    expect(px[0], lessThan(80));
    ch.dispose();
    out.dispose();
  });

  test('a blank photo reports that no ink was found', () {
    final m = cv.Mat.fromScalar(200, 200, cv.MatType.CV_8UC3, cv.Scalar(240, 240, 240));
    expect(() => extractSignature(ImageOps.encodeJpeg(m)), throwsFormatException);
    m.dispose();
  });
}
