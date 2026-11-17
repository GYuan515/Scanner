import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:doc_scanner/data/exporter.dart';
import 'package:doc_scanner/ocr/ocr_result.dart';

void main() {
  final fonts = PdfFonts(
    File('assets/fonts/Roboto-Regular.ttf').readAsBytesSync(),
    File('assets/fonts/DroidSansFallbackFull.ttf').readAsBytesSync(),
  );
  final page = File('test/fixtures/ocr_page.jpg').readAsBytesSync();

  OcrLine line(double x, double y, double w, double h, String t) =>
      OcrLine([Offset(x, y), Offset(x + w, y), Offset(x + w, y + h), Offset(x, y + h)], t, 1);

  final ocr = OcrResult(width: 1240, height: 1754, rows: [
    [line(94, 128, 460, 70, '增值税专用发票')],
    [line(97, 258, 700, 40, '购买方名称：上海某某科技有限公司')],
    [line(97, 491, 760, 40, 'The quick brown fox jumps over the lazy dog.')],
    [line(99, 636, 270, 36, '电话021-68881234'), line(384, 636, 330, 36, '邮箱test@example.com')],
  ]).toJsonString();

  String raw(Uint8List b) => String.fromCharCodes(b);

  test('searchable PDF embeds subset fonts with a ToUnicode map', () async {
    final bytes = await Exporter.pdfBytes([PdfPageInput(Uint8List.fromList(page), ocr)], const PdfOptions(), fonts);
    final s = raw(bytes);
    expect(s, startsWith('%PDF-'));
    expect(RegExp(r'/ToUnicode').allMatches(s).length, 2); // Latin + CJK font
    expect(s, contains('/FontFile2'));
    // Subsetting keeps the 4 MB CJK font out: image (~130 KB) + a few KB.
    expect(bytes.length, lessThan(page.length + 120 * 1024));
    // For a manual check with a PDF reader / pypdf.
    Directory('build').createSync(recursive: true);
    File('build/searchable_test.pdf').writeAsBytesSync(bytes);
  });

  test('no text layer without OCR or when switched off', () async {
    final plain = await Exporter.pdfBytes([PdfPageInput(Uint8List.fromList(page))], const PdfOptions(), fonts);
    expect(raw(plain), isNot(contains('/FontFile2')));
    final off = await Exporter.pdfBytes(
        [PdfPageInput(Uint8List.fromList(page), ocr)], const PdfOptions(searchable: false), fonts);
    expect(raw(off), isNot(contains('/FontFile2')));
  });
}
