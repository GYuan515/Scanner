import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doc_scanner/convert/doc_model.dart';
import 'package:doc_scanner/convert/docx_writer.dart';
import 'package:doc_scanner/convert/layout.dart';
import 'package:doc_scanner/convert/table.dart';
import 'package:doc_scanner/convert/xlsx_writer.dart';
import 'package:doc_scanner/ocr/ocr_result.dart';

/// Whole conversion of the reference page (title, paragraphs, a table with
/// a merged header, a figure) from recorded model outputs.
void main() {
  const dir = 'test/fixtures/layout';
  final expected = jsonDecode(File('$dir/expected.json').readAsStringSync()) as Map<String, dynamic>;
  final ocr = OcrResult.fromJsonString(File('$dir/ocr.json').readAsStringSync());

  Float32List bin(String name) {
    final b = File('$dir/$name').readAsBytesSync();
    return b.buffer.asFloat32List(b.offsetInBytes, b.lengthInBytes ~/ 4);
  }

  PageInput page() {
    final labels = const LineSplitter().convert(File('assets/models/layout_labels.txt').readAsStringSync());
    final regions = LayoutDecoder.decode(
      [for (var i = 0; i < 4; i++) bin('layout_out$i.bin')],
      [for (var i = 4; i < 8; i++) bin('layout_out$i.bin')],
      labels.length,
      1240,
      1754,
    );
    final p = PageInput(width: 1240, height: 1754, lines: ocr.lines.toList(), regions: regions);
    final t = (expected['tables'] as List).single as Map<String, dynamic>;
    final vocab = TableDecoder.vocabulary(const LineSplitter().convert(File('assets/models/table_tokens.txt').readAsStringSync()));
    final (structure, boxes) = TableDecoder.decode(bin('table0_loc.bin'), bin('table0_probs.bin'), t['steps'] as int, vocab, (t['ratio'] as num).toDouble());
    final crop = (t['crop'] as List).cast<num>();
    final grid = TableDecoder.grid(structure, boxes, origin: Offset(crop[0].toDouble(), crop[1].toDouble()));
    final tableIndex = regions.indexWhere((r) => r.kind == RegionKind.table);
    final tableBox = regions[tableIndex].box;
    TableDecoder.fill(grid, ocr.lines.where((l) => tableBox.inflate(4).contains(l.bounds.center)));
    p.tables[tableIndex] = grid;
    final fig = regions.indexWhere((r) => r.kind == RegionKind.figure);
    p.crops[fig] = (Uint8List.fromList(File('test/fixtures/ocr_page.jpg').readAsBytesSync()), 1240, 1754);
    return p;
  }

  String part(Uint8List zip, String name) =>
      utf8.decode(ZipDecoder().decodeBytes(zip).files.firstWhere((f) => f.name == name).content as List<int>);

  test('table cells get the right text', () {
    final p = page();
    final grid = p.tables.values.single;
    expect(grid.toRows(), [
      ['季度', '预算与支出', '', '备注'],
      ['第一季度', '120', '115', '正常'],
      ['第二季度', '150', '162', '超支8%'],
      ['第三季度', '130', '128', '正常'],
      ['第四季度', '160', '149', '结余'],
    ]);
  });

  test('page becomes heading, paragraphs, caption, table, image in reading order', () {
    final p = page();
    final blocks = PageAnalyzer.blocks(p, headingHeight: PageAnalyzer.headingHeight([p]));
    final kinds = blocks.map((b) => switch (b) {
          HeadingBlock(:final level) => 'H$level',
          ParagraphBlock(:final caption) => caption ? 'caption' : 'p',
          TableBlock() => 'table',
          ImageBlock() => 'image',
          PageBreakBlock() => 'break',
        });
    // The last block's two sentences have no paragraph cue (indent, gap or
    // short line before the last), so they stay one paragraph.
    expect(kinds.toList(), ['H1', 'p', 'p', 'caption', 'table', 'image', 'caption', 'p']);
    expect((blocks.last as ParagraphBlock).text, '下一年度将继续加强预算管理，提高经费使用效率。各部门应按季度提交执行情况报告。');
    expect((blocks[2] as ParagraphBlock).text, startsWith('全年共完成重点项目八个'));
    expect((blocks[0] as HeadingBlock).text, '年度工作总结报告');
    // A wrapped line is joined back without a break or a space.
    expect((blocks[1] as ParagraphBlock).text, startsWith('本报告总结了本年度的主要工作情况'));
    // (The reference OCR drops one character at that line end; what matters
    // is that the wrapped line is joined with no break or space.)
    expect((blocks[1] as ParagraphBlock).text, endsWith('等方面的容。'));
  });

  test('docx and xlsx contain the content', () {
    final p = page();
    final blocks = PageAnalyzer.blocks(p, headingHeight: PageAnalyzer.headingHeight([p]));
    final docx = DocxWriter.write(blocks, title: '测试');
    final doc = part(docx, 'word/document.xml');
    expect(doc, contains('<w:pStyle w:val="Heading1"/>'));
    // Schema order in the heading style: spacing before jc.
    final styles = part(docx, 'word/styles.xml');
    final h1 = styles.substring(styles.indexOf('w:styleId="Heading1"'));
    expect(h1.indexOf('<w:spacing'), lessThan(h1.indexOf('<w:jc')));
    expect(doc, contains('年度工作总结报告'));
    expect(doc, contains('<w:gridSpan w:val="2"/>'));
    expect(doc, contains('超支8%'));
    expect(doc, contains('r:embed="rIdImg1"'));
    expect(ZipDecoder().decodeBytes(docx).files.map((f) => f.name), contains('word/media/image1.jpeg'));

    final xlsx = XlsxWriter.write([SheetData('第1页 表1', p.tables.values.single)]);
    final sheet = part(xlsx, 'xl/worksheets/sheet1.xml');
    expect(sheet, contains('<mergeCell ref="B1:C1"/>'));
    expect(sheet, contains('<c r="B2" s="1"><v>120</v></c>'), reason: 'numbers are numeric');
    expect(sheet, contains('超支8%'));
    expect(part(xlsx, 'xl/workbook.xml'), contains('name="第1页 表1"'));

    Directory('build').createSync(recursive: true);
    File('build/convert_test.docx').writeAsBytesSync(docx);
    File('build/convert_test.xlsx').writeAsBytesSync(xlsx);
  });

  test('xlsx helpers', () {
    expect(XlsxWriter.col(0), 'A');
    expect(XlsxWriter.col(25), 'Z');
    expect(XlsxWriter.col(26), 'AA');
    expect(XlsxWriter.numberOf('1,280.50'), 1280.5);
    expect(XlsxWriter.numberOf('-3'), -3);
    expect(XlsxWriter.numberOf('0123'), isNull);
    expect(XlsxWriter.numberOf('8%'), isNull);
    expect(XlsxWriter.numberOf('2026-11-17'), isNull);
    // Long digit strings would lose digits in Excel: keep them as text.
    expect(XlsxWriter.numberOf('110101199003071234'), isNull);
    expect(XlsxWriter.numberOf('13812345678'), isNull);
    expect(XlsxWriter.numberOf('6222021234567890'), isNull);
    expect(XlsxWriter.numberOf('1234567890'), 1234567890);
    expect(XlsxWriter.numberOf('12,345,678,901'), 12345678901);
  });

  test('regions with identical boxes both keep their text', () {
    const box = Rect.fromLTRB(100, 100, 900, 200);
    final p = PageInput(width: 1000, height: 1000, lines: [
      OcrLine(const [Offset(110, 110), Offset(800, 110), Offset(800, 150), Offset(110, 150)], '标题文字', 1),
    ], regions: const [
      LayoutRegion(RegionKind.title, box, 0.9),
      LayoutRegion(RegionKind.text, box, 0.8),
    ]);
    final blocks = PageAnalyzer.blocks(p, headingHeight: 40);
    expect(blocks.whereType<HeadingBlock>().single.text, '标题文字');
  });

  test('reading order puts the left column before the right', () {
    const full = Rect.fromLTWH(50, 50, 1100, 80);
    const l1 = Rect.fromLTWH(50, 200, 500, 300), l2 = Rect.fromLTWH(50, 520, 500, 300);
    const r1 = Rect.fromLTWH(650, 210, 500, 600);
    const foot = Rect.fromLTWH(50, 900, 1100, 80);
    expect(PageAnalyzer.readingOrder([r1, foot, l2, full, l1], 1240), [full, l1, l2, r1, foot]);
  });
}
