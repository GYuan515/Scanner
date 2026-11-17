import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;

import '../ocr/ocr_result.dart';

/// One cell of a recognized table.
class TableCell {
  TableCell(this.row, this.col, this.rowSpan, this.colSpan, this.box);
  final int row;
  final int col;
  final int rowSpan;
  final int colSpan;

  /// Page-image pixels; null if the model gave no box.
  final Rect? box;
  String text = '';

  Map<String, dynamic> toJson() => {
        'r': row,
        'c': col,
        'rs': rowSpan,
        'cs': colSpan,
        if (box != null) 'b': [box!.left, box!.top, box!.right, box!.bottom],
        't': text,
      };

  factory TableCell.fromJson(Map<String, dynamic> j) {
    final b = (j['b'] as List?)?.cast<num>();
    return TableCell(
      j['r'] as int,
      j['c'] as int,
      j['rs'] as int,
      j['cs'] as int,
      b == null ? null : Rect.fromLTRB(b[0].toDouble(), b[1].toDouble(), b[2].toDouble(), b[3].toDouble()),
    )..text = j['t'] as String? ?? '';
  }
}

class TableGrid {
  TableGrid(this.rows, this.cols, this.cells);
  final int rows;
  final int cols;
  final List<TableCell> cells;

  Map<String, dynamic> toJson() => {'rows': rows, 'cols': cols, 'cells': [for (final c in cells) c.toJson()]};

  factory TableGrid.fromJson(Map<String, dynamic> j) => TableGrid(
        j['rows'] as int,
        j['cols'] as int,
        [for (final c in j['cells'] as List) TableCell.fromJson(c as Map<String, dynamic>)],
      );

  /// Plain text grid (merged cells repeat their text in the first position
  /// only), for tests and TXT fallbacks.
  List<List<String>> toRows() {
    final g = List.generate(rows, (_) => List.filled(cols, ''));
    for (final c in cells) {
      if (c.row < rows && c.col < cols) g[c.row][c.col] = c.text;
    }
    return g;
  }
}

/// SLANet+ decoding (mirrors RapidTable's TableLabelDecode) and grid
/// building.
class TableDecoder {
  static const size = 488;

  /// Token list as the model indexes it: "sos", the dictionary with
  /// "<td>" replaced by "<td></td>", "eos".
  static List<String> vocabulary(List<String> dict) {
    final chars = [...dict];
    if (!chars.contains('<td></td>')) chars.add('<td></td>');
    chars.remove('<td>');
    return ['sos', ...chars, 'eos'];
  }

  /// Greedy decode of [probs] (steps x vocab) and [loc] (steps x 8, the
  /// cell polygon normalised to the 488 px input). [ratio] is the resize
  /// factor from the crop to the input. Cell boxes come back in crop
  /// pixels, one per "<td" token.
  static (List<String>, List<Rect>) decode(Float32List loc, Float32List probs, int steps, List<String> vocab, double ratio) {
    final v = vocab.length;
    final structure = <String>[];
    final boxes = <Rect>[];
    for (var t = 0; t < steps; t++) {
      var best = 0;
      for (var k = 1; k < v; k++) {
        if (probs[t * v + k] > probs[t * v + best]) best = k;
      }
      final tok = vocab[best];
      if (t > 0 && tok == 'eos') break;
      if (tok == 'sos' || tok == 'eos') continue;
      if (tok == '<td>' || tok == '<td' || tok == '<td></td>') {
        final p = [for (var k = 0; k < 8; k++) loc[t * 8 + k] * size / ratio];
        final xs = [p[0], p[2], p[4], p[6]], ys = [p[1], p[3], p[5], p[7]];
        boxes.add(Rect.fromLTRB(xs.reduce(math.min), ys.reduce(math.min), xs.reduce(math.max), ys.reduce(math.max)));
      }
      structure.add(tok);
    }
    return (structure, boxes);
  }

  /// Rows, columns and spans from the HTML-like tokens; [boxes] are the
  /// cells in token order, shifted by [origin] into page pixels.
  static TableGrid grid(List<String> structure, List<Rect> boxes, {Offset origin = Offset.zero}) {
    final cells = <TableCell>[];
    // occupied[r] = columns already taken in row r by rowspans from above.
    final occupied = <int, Set<int>>{};
    var row = -1, col = 0, cellIndex = 0;
    var inCell = false;
    var rs = 1, cs = 1;
    var cols = 0;

    void place() {
      final taken = occupied.putIfAbsent(row, () => {});
      while (taken.contains(col)) {
        col++;
      }
      // Model output can make a span run into cells a rowspan from above
      // already covers; shrink it so no two cells overlap (overlapping
      // merges make Excel "repair" the file and Word drop text).
      cs = cs < 1 ? 1 : cs;
      rs = rs < 1 ? 1 : rs;
      var fit = 1;
      while (fit < cs && !taken.contains(col + fit)) {
        fit++;
      }
      cs = fit;
      var rows = 1;
      while (rows < rs && ![for (var k = col; k < col + cs; k++) k].any((k) => occupied[row + rows]?.contains(k) ?? false)) {
        rows++;
      }
      rs = rows;
      final box = cellIndex < boxes.length ? boxes[cellIndex].shift(origin) : null;
      cells.add(TableCell(row, col, rs, cs, box));
      cellIndex++;
      for (var r = row; r < row + rs; r++) {
        final t = occupied.putIfAbsent(r, () => {});
        for (var c = col; c < col + cs; c++) {
          t.add(c);
        }
      }
      col += cs;
      cols = math.max(cols, col);
      rs = cs = 1;
    }

    for (final tok in structure) {
      if (tok == '<tr>') {
        row++;
        col = 0;
      } else if (tok == '<td></td>') {
        if (row < 0) row = 0;
        place();
      } else if (tok == '<td') {
        if (row < 0) row = 0;
        inCell = true;
      } else if (inCell && tok.contains('colspan')) {
        cs = int.tryParse(RegExp(r'\d+').firstMatch(tok)?[0] ?? '') ?? 1;
      } else if (inCell && tok.contains('rowspan')) {
        rs = int.tryParse(RegExp(r'\d+').firstMatch(tok)?[0] ?? '') ?? 1;
      } else if (inCell && tok == '>') {
        // attributes done; the cell is closed by </td>
      } else if (inCell && tok == '</td>') {
        inCell = false;
        place();
      }
    }
    var rows = row + 1;
    for (final c in cells) {
      rows = math.max(rows, c.row + c.rowSpan);
    }
    return TableGrid(rows, cols, cells);
  }

  /// Puts each OCR line into the cell it overlaps most (ties: the nearest
  /// one), like RapidTable's matcher; several lines in one cell are joined
  /// in reading order.
  static void fill(TableGrid grid, Iterable<OcrLine> lines) {
    final withBox = [for (final c in grid.cells) if (c.box != null) c];
    if (withBox.isEmpty) return;
    final top = withBox.map((c) => c.box!.top).reduce(math.min);
    final assigned = <TableCell, List<OcrLine>>{};
    for (final l in lines) {
      final b = l.bounds;
      if (b.bottom < top) continue; // above the table (e.g. its caption)
      TableCell? best;
      var bestIou = 0.0, bestDist = double.infinity;
      for (final c in withBox) {
        final iou = _iou(b, c.box!);
        final dist = _dist(b, c.box!);
        if (iou > bestIou || (iou == bestIou && iou > 0 && dist < bestDist)) {
          best = c;
          bestIou = iou;
          bestDist = dist;
        }
      }
      if (best != null && bestIou > 1e-8) assigned.putIfAbsent(best, () => []).add(l);
    }
    for (final MapEntry(key: cell, value: ls) in assigned.entries) {
      ls.sort((a, b) {
        final dy = a.bounds.center.dy - b.bounds.center.dy;
        if (dy.abs() > math.min(a.height, b.height) / 2) return dy.sign.toInt();
        return a.bounds.left.compareTo(b.bounds.left);
      });
      cell.text = joinText(ls.map((l) => l.text.trim()));
    }
  }

  /// Joins text pieces: no space between CJK pieces, one space otherwise.
  static String joinText(Iterable<String> parts) {
    final sb = StringBuffer();
    for (final p in parts) {
      if (p.isEmpty) continue;
      if (sb.isNotEmpty) {
        final prev = sb.toString();
        if (!(_isCjk(prev.codeUnitAt(prev.length - 1)) || _isCjk(p.codeUnitAt(0)))) sb.write(' ');
      }
      sb.write(p);
    }
    return sb.toString();
  }

  static bool _isCjk(int u) => (u >= 0x2E80 && u <= 0x9FFF) || (u >= 0xFF00 && u <= 0xFFEF) || (u >= 0x3000 && u <= 0x303F);

  static double _iou(Rect a, Rect b) {
    final i = a.intersect(b);
    if (i.width <= 0 || i.height <= 0) return 0;
    final inter = i.width * i.height;
    return inter / (a.width * a.height + b.width * b.height - inter);
  }

  /// RapidTable's distance: corner-to-corner L1 plus the smaller of the
  /// two corner differences.
  static double _dist(Rect a, Rect b) {
    final dis = (b.left - a.left).abs() + (b.top - a.top).abs() + (b.right - a.right).abs() + (b.bottom - a.bottom).abs();
    final d2 = (b.left - a.left).abs() + (b.top - a.top).abs();
    final d3 = (b.right - a.right).abs() + (b.bottom - a.bottom).abs();
    return dis + math.min(d2, d3);
  }
}
