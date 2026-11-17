import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:pdf/pdf.dart' as pdflib;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';
import 'package:doc_scanner/data/exporter.dart';
import 'package:doc_scanner/data/importer.dart';
import 'package:doc_scanner/markup/geometry.dart';
import 'package:doc_scanner/pdf/pdf_crypto.dart';
import 'package:doc_scanner/pdf/pdf_tools.dart';
import 'package:doc_scanner/scan/image_ops.dart';

/// Runs against real PDFium. On the build machine set PDFIUM_PATH to a
/// pdfium.dll (pypdfium2 ships one); without it the PDFium tests skip.
final _pdfium = Platform.environment['PDFIUM_PATH'];
final _skip = _pdfium == null || !File(_pdfium!).existsSync() ? 'PDFIUM_PATH not set' : null;

Future<Uint8List> textPdf(List<String> pages, {String? password}) async {
  final doc = pw.Document();
  if (password != null) doc.document.encryption = Aes256Encryption(doc.document, password);
  for (final t in pages) {
    doc.addPage(pw.Page(pageFormat: pdflib.PdfPageFormat.a5, build: (_) => pw.Text(t)));
  }
  return doc.save();
}

Future<List<String>> texts(Uint8List bytes, {String? password}) async {
  final d = await PdfTools.openData(bytes, 't.pdf', password: password);
  try {
    return [for (final p in d.pages) ((await p.loadText())?.fullText ?? '').trim()];
  } finally {
    await d.dispose();
  }
}

void main() {
  group('page ranges', () {
    test('ranges, singles, open ends, reversed, full-width punctuation', () {
      expect(parsePageRanges('1-3, 5', 10), [1, 2, 3, 5]);
      expect(parsePageRanges('8-', 10), [8, 9, 10]);
      expect(parsePageRanges('-2', 10), [1, 2]);
      expect(parsePageRanges('3-1', 10), [3, 2, 1]);
      expect(parsePageRanges('2，4－5', 10), [2, 4, 5]);
    });

    test('bad input explains itself', () {
      expect(() => parsePageRanges('0', 5), throwsFormatException);
      expect(() => parsePageRanges('6', 5), throwsFormatException);
      expect(() => parsePageRanges('a-b', 5), throwsFormatException);
      expect(() => parsePageRanges(' , ', 5), throwsFormatException);
    });

    test('splitEvery', () {
      expect(splitEvery(5, 2), [
        [1, 2],
        [3, 4],
        [5],
      ]);
      expect(() => splitEvery(5, 0), throwsFormatException);
    });
  });

  group('with PDFium', skip: _skip, () {
    setUpAll(() async => pdfrxInitialize());

    test('merge keeps every page in order', () async {
      final a = await PdfTools.openData(await textPdf(['A1', 'A2']), 'a.pdf');
      final b = await PdfTools.openData(await textPdf(['B1']), 'b.pdf');
      final merged = await PdfTools.merge([a, b]);
      await a.dispose();
      await b.dispose();
      expect(await texts(merged), ['A1', 'A2', 'B1']);
    });

    test('extract, reorder and rotate', () async {
      final d = await PdfTools.openData(await textPdf(['P1', 'P2', 'P3']), 'd.pdf');
      final out = await PdfTools.assemble([
        (doc: d, page: 3, quarterTurns: 0),
        (doc: d, page: 1, quarterTurns: 1),
      ]);
      await d.dispose();
      expect(await texts(out), ['P3', 'P1']);
      final r = await PdfTools.openData(out, 'r.pdf');
      expect(r.pages[1].rotation, PdfPageRotation.clockwise90);
      // A5 portrait turned a quarter: width and height swap.
      expect(r.pages[1].width, greaterThan(r.pages[1].height));
      await r.dispose();
    });

    test('split into groups', () async {
      final d = await PdfTools.openData(await textPdf(['1', '2', '3', '4', '5']), 'd.pdf');
      final parts = await PdfTools.split(d, splitEvery(5, 2));
      await d.dispose();
      expect([for (final p in parts) await texts(p)], [
        ['1', '2'],
        ['3', '4'],
        ['5'],
      ]);
    });

    test('decrypt needs the password and removes it', () async {
      final locked = await textPdf(['secret 42'], password: 'abc123'); // built-in font: ASCII only
      await expectLater(PdfTools.openData(locked, 'l.pdf'), throwsA(anything));
      await expectLater(PdfTools.openData(locked, 'l.pdf', password: 'wrong'), throwsA(anything));
      final d = await PdfTools.openData(locked, 'l.pdf', password: 'abc123');
      final open = await PdfTools.decrypt(d);
      await d.dispose();
      expect(await texts(open), ['secret 42']);
    });

    test('importing an encrypted PDF into the library uses the password', () async {
      final locked = await textPdf(['secret'], password: 'abc123');
      await expectLater(Importer.fromPdf(locked), throwsA(isA<PdfPasswordException>()));
      await expectLater(Importer.fromPdf(locked, password: 'wrong'), throwsA(isA<PdfPasswordException>()));
      final drafts = await Importer.fromPdf(locked, password: 'abc123');
      expect(drafts, hasLength(1));
    });

    test('pages to JPEG at the chosen dpi', () async {
      final d = await PdfTools.openData(await textPdf(['x']), 'd.pdf');
      final jpgs = await PdfTools.toImages(d, dpi: 100);
      await d.dispose();
      // A5 = 419.5 x 595.3 pt -> 583 x 827 px at 100 dpi.
      expect(jpegSize(jpgs.single), (583, 827));
    });

    test('compress keeps page sizes, shrinks a photo-heavy file, can add a password', () async {
      // A noisy photo-like page compresses badly at high quality.
      final m = cv.Mat.zeros(2400, 1700, cv.MatType.CV_8UC3);
      cv.randu(m, cv.Scalar.all(0), cv.Scalar.all(255));
      final heavy = await Exporter.pdfBytes(
        [PdfPageInput(ImageOps.encodeJpeg(m, quality: 95))],
        const PdfOptions(size: PdfPageSize.a4, searchable: false),
      );
      m.dispose();
      final d = await PdfTools.openData(heavy, 'h.pdf');
      final small = await PdfTools.compress(d, dpi: 72, quality: 50, password: 'pw');
      final w = d.pages.first.width, h = d.pages.first.height;
      await d.dispose();
      expect(small.length, lessThan(heavy.length ~/ 4));
      await expectLater(PdfTools.openData(small, 's.pdf'), throwsA(anything));
      final s = await PdfTools.openData(small, 's.pdf', password: 'pw');
      expect(s.pages.first.width, closeTo(w, 0.5));
      expect(s.pages.first.height, closeTo(h, 0.5));
      await s.dispose();
    });

    test('images to an encrypted PDF', () async {
      final m = cv.Mat.fromScalar(600, 400, cv.MatType.CV_8UC3, cv.Scalar(200, 200, 200));
      final jpg = ImageOps.encodeJpeg(m);
      m.dispose();
      final out = await PdfTools.imagesToPdf([jpg, jpg], const PdfOptions(size: PdfPageSize.fit, password: '密码'));
      final d = await PdfTools.openData(out, 'i.pdf', password: '密码');
      expect(d.pages.length, 2);
      // 400 px at 150 dpi = 192 pt.
      expect(d.pages.first.width, closeTo(192, 0.5));
      await d.dispose();
    });
  });
}
