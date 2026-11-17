import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:doc_scanner/convert/layout.dart';
import 'package:doc_scanner/convert/table.dart';
import 'package:doc_scanner/ocr/ocr_result.dart';

/// Replays raw model outputs recorded by _tools/ref_layout.py (Python +
/// ONNX Runtime) and checks the Dart decoders give the same results.
void main() {
  const dir = 'test/fixtures/layout';
  final expected = jsonDecode(File('$dir/expected.json').readAsStringSync()) as Map<String, dynamic>;

  Float32List bin(String name) {
    final b = File('$dir/$name').readAsBytesSync();
    return b.buffer.asFloat32List(b.offsetInBytes, b.lengthInBytes ~/ 4);
  }

  test('layout regions match the Python reference', () {
    final labels = const LineSplitter().convert(File('assets/models/layout_labels.txt').readAsStringSync());
    final regions = LayoutDecoder.decode(
      [for (var i = 0; i < 4; i++) bin('layout_out$i.bin')],
      [for (var i = 4; i < 8; i++) bin('layout_out$i.bin')],
      labels.length,
      1240,
      1754,
    )..sort((a, b) => a.box.top.compareTo(b.box.top));
    final want = (expected['regions'] as List).cast<Map<String, dynamic>>();
    expect(regions.length, want.length);
    for (var i = 0; i < want.length; i++) {
      expect(regions[i].kind, RegionKind.fromLabel(want[i]['label'] as String), reason: '$i');
      final b = (want[i]['box'] as List).cast<num>();
      expect(regions[i].box.left, closeTo(b[0], 0.5));
      expect(regions[i].box.top, closeTo(b[1], 0.5));
      expect(regions[i].box.right, closeTo(b[2], 0.5));
      expect(regions[i].box.bottom, closeTo(b[3], 0.5));
      expect(regions[i].score, closeTo(want[i]['score'] as num, 1e-4));
    }
    expect(regions.map((r) => r.kind), [
      RegionKind.title,
      RegionKind.text,
      RegionKind.tableCaption,
      RegionKind.table,
      RegionKind.figure,
      RegionKind.figureCaption,
      RegionKind.text,
    ]);
  });

  test('table structure, cells and merged header match the reference', () {
    final t = (expected['tables'] as List).single as Map<String, dynamic>;
    final dict = const LineSplitter().convert(File('assets/models/table_tokens.txt').readAsStringSync());
    final vocab = TableDecoder.vocabulary(dict);
    expect(vocab.length, 50);
    final steps = t['steps'] as int;
    final (structure, boxes) = TableDecoder.decode(bin('table0_loc.bin'), bin('table0_probs.bin'), steps, vocab, (t['ratio'] as num).toDouble());
    expect(structure, (t['structure'] as List).cast<String>());
    final want = (t['cells'] as List).cast<List>();
    expect(boxes.length, want.length);
    for (var i = 0; i < want.length; i++) {
      final p = want[i].cast<num>();
      expect(boxes[i].left, closeTo([p[0], p[2], p[4], p[6]].reduce((a, b) => a < b ? a : b), 0.01));
    }

    final crop = (t['crop'] as List).cast<num>();
    final grid = TableDecoder.grid(structure, boxes, origin: Offset(crop[0].toDouble(), crop[1].toDouble()));
    expect((grid.rows, grid.cols), (5, 4));
    final header = grid.cells.where((c) => c.row == 0).toList();
    expect(header.map((c) => (c.col, c.colSpan)), [(0, 1), (1, 2), (3, 1)]);
    // Cell boxes land on the drawn table (page x 110..1120, y ~551..871).
    final first = grid.cells.first.box!;
    expect(first.left, closeTo(110, 25));
  });

  test('grid handles rowspan and fills text by overlap', () {
    // 2x3 table; cell (0,0) spans two rows.
    final structure = ['<tr>', '<td', ' rowspan="2"', '>', '</td>', '<td></td>', '<td></td>', '</tr>', '<tr>', '<td></td>', '<td></td>', '</tr>'];
    final boxes = [
      const Rect.fromLTRB(0, 0, 100, 100),
      const Rect.fromLTRB(100, 0, 200, 50),
      const Rect.fromLTRB(200, 0, 300, 50),
      const Rect.fromLTRB(100, 50, 200, 100),
      const Rect.fromLTRB(200, 50, 300, 100),
    ];
    final grid = TableDecoder.grid(structure, boxes);
    expect((grid.rows, grid.cols), (2, 3));
    expect(grid.cells.map((c) => (c.row, c.col)), [(0, 0), (0, 1), (0, 2), (1, 1), (1, 2)]);
    OcrLine line(double l, double t, double r, double b, String s) =>
        OcrLine([Offset(l, t), Offset(r, t), Offset(r, b), Offset(l, b)], s, 1);
    TableDecoder.fill(grid, [
      line(10, 40, 90, 60, '合并'),
      line(110, 10, 190, 40, 'B1'),
      line(210, 5, 290, 22, '第一行'),
      line(210, 26, 290, 45, '第二行'),
      line(110, 60, 190, 90, 'B2'),
      line(0, -40, 100, -10, '表格上方的标题'),
    ]);
    expect(grid.toRows(), [
      ['合并', 'B1', '第一行第二行'],
      ['', 'B2', ''],
    ]);
  });

  test('spans never overlap cells a rowspan already covers', () {
    // Row 0: A | B (rowspan 2) | C. Row 1: a colspan=3 starting at col 0
    // would run over B, so it must shrink to the one free column.
    final structure = ['<tr>', '<td></td>', '<td', ' rowspan="2"', '>', '</td>', '<td></td>', '</tr>',
      '<tr>', '<td', ' colspan="3"', '>', '</td>', '</tr>'];
    final grid = TableDecoder.grid(structure, const []);
    final last = grid.cells.last;
    expect((last.row, last.col, last.colSpan), (1, 0, 1));
    final covered = <(int, int)>{};
    for (final c in grid.cells) {
      for (var r = c.row; r < c.row + c.rowSpan; r++) {
        for (var k = c.col; k < c.col + c.colSpan; k++) {
          expect(covered.add((r, k)), isTrue, reason: 'overlap at ($r,$k)');
        }
      }
    }
  });

  test('joinText spaces Latin words but not Chinese', () {
    expect(TableDecoder.joinText(['合计', '金额']), '合计金额');
    expect(TableDecoder.joinText(['Total', 'amount']), 'Total amount');
    expect(TableDecoder.joinText(['金额', 'USD']), '金额USD');
  });
}
