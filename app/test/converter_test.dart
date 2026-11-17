import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:pdf/pdf.dart' as pdflib;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';
import 'package:doc_scanner/convert/converter.dart';
import 'package:doc_scanner/convert/layout.dart';
import 'package:doc_scanner/convert/pdf_text.dart';
import 'package:doc_scanner/convert/table.dart';
import 'package:doc_scanner/data/db.dart';
import 'package:doc_scanner/data/page_store.dart';
import 'package:doc_scanner/ocr/ocr_queue.dart';
import 'package:doc_scanner/ocr/ocr_result.dart';
import 'package:doc_scanner/ocr/ocr_service.dart';
import 'package:doc_scanner/scan/image_ops.dart';

final _pdfium = Platform.environment['PDFIUM_PATH'];
final _skip = _pdfium == null || !File(_pdfium!).existsSync() ? 'PDFIUM_PATH not set' : null;

OcrLine line(double l, double t, double r, double b, String s) =>
    OcrLine([Offset(l, t), Offset(r, t), Offset(r, b), Offset(l, b)], s, 1);

/// Layout model stand-in: fixed regions; tables are 2x2 grids over the box.
class FakeLayout implements LayoutEngine {
  FakeLayout(this.regions);
  final List<LayoutRegion> regions;
  final calls = <String>[];

  @override
  Future<List<LayoutRegion>> layout(String path) async {
    calls.add('layout');
    return regions;
  }

  @override
  Future<TableGrid> table(String path, Rect region) async {
    calls.add('table');
    final w = region.width / 2, h = region.height / 2;
    Rect cell(int r, int c) => Rect.fromLTWH(region.left + c * w, region.top + r * h, w, h);
    return TableGrid(2, 2, [
      TableCell(0, 0, 1, 1, cell(0, 0)),
      TableCell(0, 1, 1, 1, cell(0, 1)),
      TableCell(1, 0, 1, 1, cell(1, 0)),
      TableCell(1, 1, 1, 1, cell(1, 1)),
    ]);
  }
}

class FakeOcr implements OcrEngine {
  int calls = 0;
  @override
  Future<OcrResult> recognizeFile(String path, {Rect? region}) async {
    calls++;
    return OcrResult(width: 600, height: 800, rows: [
      [line(50, 50, 400, 90, 'OCR 标题')],
    ]);
  }
}

String docXml(Uint8List docx) =>
    utf8.decode(ZipDecoder().decodeBytes(docx).files.firstWhere((f) => f.name == 'word/document.xml').content as List<int>);

void main() {
  test('PDF characters become lines in image pixels', () {
    // "AB" on one baseline, "C" on the next line without an explicit break.
    final rects = [
      const PdfRect(10, 700, 20, 688),
      const PdfRect(20, 700, 30, 688),
      const PdfRect(10, 680, 20, 668),
    ];
    final lines = linesFromChars('ABC', rects, 800, 2);
    expect(lines.map((l) => l.text), ['AB', 'C']);
    expect(lines.first.bounds, const Rect.fromLTRB(20, 200, 60, 224));
    expect(hasTextLayer(lines), isFalse);
    expect(linesFromChars('Hello\nWorld', [for (var i = 0; i < 11; i++) PdfRect(10.0 + i, 700, 11.0 + i, 690)], 800, 1).map((l) => l.text), ['Hello', 'World']);
  });

  test('table cells typed on one baseline become separate lines', () {
    // "Name" at x 10..34, "Age" at 80..98 (gap 46 pt >> 1.5 x 12 pt).
    final rects = [
      for (var i = 0; i < 4; i++) PdfRect(10.0 + i * 6, 700, 16.0 + i * 6, 688),
      for (var i = 0; i < 3; i++) PdfRect(80.0 + i * 6, 700, 86.0 + i * 6, 688),
    ];
    expect(linesFromChars('NameAge', rects, 800, 1).map((l) => l.text), ['Name', 'Age']);
  });

  test('characters outside the BMP keep the boxes aligned', () {
    // One rect per code point: the emoji is 2 UTF-16 units but 1 rect.
    final rects = [for (var i = 0; i < 4; i++) PdfRect(10.0 + i * 10, 700, 20.0 + i * 10, 690)];
    final lines = linesFromChars('a😀bc', rects, 800, 1);
    expect(lines.single.text, 'a😀bc');
    expect(lines.single.bounds.right, 50);
    // Counts that match neither way: give up (the caller uses OCR).
    expect(linesFromChars('abc', [rects.first], 800, 1), isEmpty);
  });

  group('scanned document', () {
    late AppDatabase db;
    late Directory tmp;
    late PageStore store;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      tmp = Directory.systemTemp.createTempSync('scanner_convert_');
      store = PageStore(db, tmp);
    });

    tearDown(() async {
      await db.close();
      tmp.deleteSync(recursive: true);
    });

    test('uses stored text, fills tables, crops figures, writes docx and xlsx', () async {
      final m = cv.Mat.fromScalar(800, 600, cv.MatType.CV_8UC3, cv.Scalar.all(255));
      final doc = await store.createDocument('文档', [DraftPage(original: ImageOps.encodeJpeg(m), width: 600, height: 800, filter: ScanFilter.original)]);
      m.dispose();
      final pg = (await db.pagesOf(doc)).single;
      final text = OcrResult(width: 600, height: 800, rows: [
        [line(100, 40, 500, 90, '报告标题')],
        [line(60, 120, 540, 150, '正文第一段，说明情况。')],
        [line(80, 320, 200, 350, '名称'), line(330, 320, 450, 350, '数量')],
        [line(80, 420, 200, 450, '纸张'), line(330, 420, 450, 450, '12')],
      ]);
      await db.saveOcr(pg.id, text: text.text, json: text.toJsonString(), processedFile: pg.processedFile);

      final layout = FakeLayout([
        const LayoutRegion(RegionKind.title, Rect.fromLTRB(90, 30, 510, 100), 0.9),
        const LayoutRegion(RegionKind.text, Rect.fromLTRB(50, 110, 550, 160), 0.9),
        const LayoutRegion(RegionKind.table, Rect.fromLTRB(60, 300, 540, 480), 0.9),
        const LayoutRegion(RegionKind.figure, Rect.fromLTRB(100, 550, 500, 750), 0.9),
      ]);
      final ocr = FakeOcr();
      final conv = DocumentConverter(layout: layout, ocr: ocr);
      final queue = OcrQueue(db, store, () async => ocr);
      final pages = await conv.fromScans([(await db.pageById(pg.id))!], store, queue, (_) {});
      expect(ocr.calls, 0, reason: 'stored text is reused');
      expect(layout.calls, ['layout', 'table']);
      final page = pages.single;
      expect(page.tables.values.single.toRows(), [
        ['名称', '数量'],
        ['纸张', '12'],
      ]);
      expect(page.crops.values.single.$2, 400);

      final xml = docXml(await DocumentConverter.toDocx(pages, title: '文档'));
      expect(xml.indexOf('报告标题'), lessThan(xml.indexOf('正文第一段')));
      expect(xml, contains('<w:tbl>'));
      expect(xml, contains('r:embed="rIdImg1"'));

      final (xlsx, tables) = await DocumentConverter.toXlsx(pages);
      expect(tables, 1);
      expect(ZipDecoder().decodeBytes(xlsx).files.map((f) => f.name), contains('xl/worksheets/sheet1.xml'));
    });

    test('without tables the workbook holds the text rows', () async {
      final p = DocumentConverter.textGrid([line(0, 0, 50, 20, 'a'), line(100, 2, 150, 22, 'b'), line(0, 40, 50, 60, 'c')]);
      expect(p.toRows(), [
        ['a', 'b'],
        ['c', ''],
      ]);
    });
  });

  group('PDF with a text layer', skip: _skip, () {
    setUpAll(() async => pdfrxInitialize());

    test('takes text from the PDF instead of OCR', () async {
      final d = pw.Document()
        ..addPage(pw.Page(
          pageFormat: pdflib.PdfPageFormat.a4,
          build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text('Quarterly report', style: const pw.TextStyle(fontSize: 24)),
            pw.SizedBox(height: 20),
            pw.Text('Revenue grew in every region this quarter.'),
          ]),
        ));
      final pdf = await PdfDocument.openData(await d.save(), sourceName: 't.pdf');
      final work = Directory.systemTemp.createTempSync('scanner_pdfconv_');
      final ocr = FakeOcr();
      // One text region over the whole page.
      final layout = FakeLayout([const LayoutRegion(RegionKind.text, Rect.fromLTRB(0, 0, 1240, 1754), 0.9)]);
      final pages = await DocumentConverter(layout: layout, ocr: ocr).fromPdf(pdf, work, (_) {});
      await pdf.dispose();
      work.deleteSync(recursive: true);
      expect(ocr.calls, 0);
      expect(pages.single.lines.map((l) => l.text), ['Quarterly report', 'Revenue grew in every region this quarter.']);
      // 150 dpi page image: A4 width 595 pt -> 1240 px.
      expect(pages.single.width, 1240);
      final xml = docXml(await DocumentConverter.toDocx(pages));
      expect(xml, contains('Revenue grew in every region this quarter.'));
    });
  });
}
