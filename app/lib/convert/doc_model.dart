import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Rect;

import '../ocr/ocr_result.dart';
import 'layout.dart';
import 'table.dart';

/// Content of a converted document, independent of the output format.
sealed class DocBlock {
  const DocBlock();
}

class HeadingBlock extends DocBlock {
  const HeadingBlock(this.text, this.level);
  final String text;

  /// 1 = largest headings in the document, 2 = the rest.
  final int level;
}

class ParagraphBlock extends DocBlock {
  const ParagraphBlock(this.text, {this.caption = false, this.indent = false});
  final String text;

  /// Figure / table caption: centred, smaller.
  final bool caption;

  /// First line indented (two characters), as Chinese body text usually is.
  final bool indent;
}

class TableBlock extends DocBlock {
  const TableBlock(this.grid, this.widthFraction);
  final TableGrid grid;

  /// Table width relative to the page image width.
  final double widthFraction;
}

class ImageBlock extends DocBlock {
  const ImageBlock(this.jpeg, this.width, this.height, this.widthFraction);
  final Uint8List jpeg;
  final int width;
  final int height;

  /// Image width relative to the page image width.
  final double widthFraction;
}

class PageBreakBlock extends DocBlock {
  const PageBreakBlock();
}

/// Everything known about one page before it becomes blocks.
class PageInput {
  PageInput({required this.width, required this.height, required this.lines, required this.regions});
  final int width;
  final int height;
  final List<OcrLine> lines;
  final List<LayoutRegion> regions;

  /// Recognized tables, by index into [regions].
  final tables = <int, TableGrid>{};

  /// Cropped JPEGs of figure / equation regions, by index into [regions].
  final crops = <int, (Uint8List, int, int)>{};
}

/// Turns layout regions + text lines into blocks in reading order.
class PageAnalyzer {
  /// Regions worth keeping, duplicates and running headers removed.
  static List<int> usefulRegions(PageInput p) {
    final idx = <int>[];
    for (var i = 0; i < p.regions.length; i++) {
      final k = p.regions[i].kind;
      if (k == RegionKind.header || k == RegionKind.footer) continue;
      idx.add(i);
    }
    // Drop a region mostly inside a bigger one of the same kind, and text
    // inside a table or figure (the table / image already covers it).
    bool covered(int a, int b) {
      final ra = p.regions[a].box, rb = p.regions[b].box;
      final inter = ra.intersect(rb);
      if (inter.width <= 0 || inter.height <= 0) return false;
      return inter.width * inter.height > 0.8 * ra.width * ra.height && rb.width * rb.height >= ra.width * ra.height;
    }

    bool container(RegionKind k) => k == RegionKind.table || k == RegionKind.figure;
    return [
      for (final a in idx)
        if (!idx.any((b) {
          if (a == b) return false;
          final ka = p.regions[a].kind, kb = p.regions[b].kind;
          return covered(a, b) && (ka == kb || container(kb)) && (ka != kb || b < a || p.regions[b].box != p.regions[a].box);
        }))
          a,
    ];
  }

  /// Reading order: full-width regions split the page into bands; inside a
  /// band the left column is read before the right one.
  static List<Rect> readingOrder(List<Rect> boxes, double pageWidth) =>
      [for (final i in readingOrderIndices(boxes, pageWidth)) boxes[i]];

  /// [readingOrder] as indices into [boxes] (equal boxes stay distinct).
  static List<int> readingOrderIndices(List<Rect> boxes, double pageWidth) {
    final sorted = List<int>.generate(boxes.length, (i) => i)..sort((a, b) => boxes[a].top.compareTo(boxes[b].top));
    final out = <int>[];
    var band = <int>[];
    void byTop(List<int> l) => l.sort((a, b) => boxes[a].top.compareTo(boxes[b].top));
    void flush() {
      final mid = pageWidth / 2;
      final left = band.where((i) => boxes[i].center.dx < mid).toList();
      final right = band.where((i) => boxes[i].center.dx >= mid).toList();
      byTop(left);
      byTop(right);
      // Only treat it as two columns when both sides really have blocks.
      if (left.isEmpty || right.isEmpty) {
        byTop(band);
        out.addAll(band);
      } else {
        out
          ..addAll(left)
          ..addAll(right);
      }
      band = [];
    }

    for (final i in sorted) {
      if (boxes[i].width > pageWidth * 0.6) {
        flush();
        out.add(i);
      } else {
        band.add(i);
      }
    }
    flush();
    return out;
  }

  static List<DocBlock> blocks(PageInput p, {required double headingHeight}) {
    final keep = usefulRegions(p);
    // Each line goes to the smallest kept region holding its centre.
    final owned = <int, List<OcrLine>>{for (final i in keep) i: []};
    final orphans = <OcrLine>[];
    for (final l in p.lines) {
      final c = l.bounds.center;
      int? best;
      for (final i in keep) {
        final b = p.regions[i].box.inflate(4);
        if (!b.contains(c)) continue;
        if (best == null || b.width * b.height < p.regions[best].box.width * p.regions[best].box.height) best = i;
      }
      if (best == null) {
        orphans.add(l);
      } else {
        owned[best]!.add(l);
      }
    }

    // Lines outside every region: grouped into paragraph-like boxes.
    final groups = _groupOrphans(orphans);
    final groupBoxes = [for (final g in groups) g.map((l) => l.bounds).reduce((a, b) => a.expandToInclude(b))];

    // Entries 0..keep.length-1 are regions, the rest orphan groups.
    final boxes = [for (final i in keep) p.regions[i].box, ...groupBoxes];
    final out = <DocBlock>[];
    for (final k in readingOrderIndices(boxes, p.width.toDouble())) {
      if (k >= keep.length) {
        final g = k - keep.length;
        out.addAll(_paragraphs(groups[g], groupBoxes[g]));
        continue;
      }
      final i = keep[k];
      final r = p.regions[i];
      final lines = owned[i]!;
      switch (r.kind) {
        case RegionKind.table:
          final grid = p.tables[i];
          if (grid != null) {
            out.add(TableBlock(grid, r.box.width / p.width));
          } else {
            out.addAll(_paragraphs(lines, r.box));
          }
        case RegionKind.figure:
        case RegionKind.equation:
          final crop = p.crops[i];
          if (crop != null) out.add(ImageBlock(crop.$1, crop.$2, crop.$3, r.box.width / p.width));
        case RegionKind.title:
          final text = _joinRows(lines);
          if (text.isEmpty) continue;
          final h = lines.isEmpty ? 0.0 : lines.map((l) => l.height).reduce(math.max);
          out.add(HeadingBlock(text, h >= headingHeight * 0.85 ? 1 : 2));
        case RegionKind.figureCaption:
        case RegionKind.tableCaption:
          final text = _joinRows(lines);
          if (text.isNotEmpty) out.add(ParagraphBlock(text, caption: true));
        default:
          out.addAll(_paragraphs(lines, r.box));
      }
    }
    return out;
  }

  /// Splits orphan lines into groups at big vertical gaps.
  static List<List<OcrLine>> _groupOrphans(List<OcrLine> lines) {
    if (lines.isEmpty) return const [];
    final rows = OcrResult.arrange(lines);
    final groups = <List<OcrLine>>[];
    var cur = <OcrLine>[...rows.first];
    for (var i = 1; i < rows.length; i++) {
      final prev = rows[i - 1].map((l) => l.bounds).reduce((a, b) => a.expandToInclude(b));
      final next = rows[i].map((l) => l.bounds).reduce((a, b) => a.expandToInclude(b));
      final h = math.min(prev.height, next.height);
      if (next.top - prev.bottom > h * 1.2) {
        groups.add(cur);
        cur = [];
      }
      cur.addAll(rows[i]);
    }
    groups.add(cur);
    return groups;
  }

  /// Text of [lines] as rows joined without breaks.
  static String _joinRows(List<OcrLine> lines) {
    final rows = OcrResult.arrange(lines);
    return _joinLines([for (final r in rows) TableDecoder.joinText(r.map((l) => l.text.trim()))]);
  }

  /// Joins wrapped lines: no space between CJK, a space between Latin
  /// words, and "exam-\nple" becomes "example".
  static String _joinLines(List<String> rows) {
    final sb = StringBuffer();
    for (final row in rows) {
      final t = row.trim();
      if (t.isEmpty) continue;
      if (sb.isEmpty) {
        sb.write(t);
        continue;
      }
      final s = sb.toString();
      final last = s.codeUnitAt(s.length - 1), first = t.codeUnitAt(0);
      if (last == 0x2D && _isLower(first)) {
        sb
          ..clear()
          ..write(s.substring(0, s.length - 1))
          ..write(t);
      } else if (_isCjk(last) || _isCjk(first)) {
        sb.write(t);
      } else {
        sb
          ..write(' ')
          ..write(t);
      }
    }
    return sb.toString();
  }

  /// One paragraph per indented start, vertical gap, or after a line that
  /// stops well short of the right edge (the last line of a paragraph).
  static List<ParagraphBlock> _paragraphs(List<OcrLine> lines, Rect region) {
    if (lines.isEmpty) return const [];
    final rows = OcrResult.arrange(lines);
    final rowBoxes = [for (final r in rows) r.map((l) => l.bounds).reduce((a, b) => a.expandToInclude(b))];
    final left = rowBoxes.map((b) => b.left).reduce(math.min);
    final right = rowBoxes.map((b) => b.right).reduce(math.max);
    final paras = <ParagraphBlock>[];
    var cur = <String>[];
    var indent = false;
    Rect? prev;
    for (var i = 0; i < rows.length; i++) {
      final r = rows[i];
      final b = rowBoxes[i];
      final h = b.height;
      final indented = b.left - left > h * 1.2;
      final gap = prev != null && b.top - prev.bottom > h * 0.9;
      final prevShort = prev != null && prev.right < right - h * 2;
      if (cur.isNotEmpty && (indented || gap || prevShort)) {
        paras.add(ParagraphBlock(_joinLines(cur), indent: indent));
        cur = [];
      }
      if (cur.isEmpty) indent = indented;
      cur.add(TableDecoder.joinText(r.map((l) => l.text.trim())));
      prev = b;
    }
    if (cur.isNotEmpty) paras.add(ParagraphBlock(_joinLines(cur), indent: indent));
    return paras.where((p) => p.text.isNotEmpty).toList();
  }

  static bool _isLower(int u) => u >= 0x61 && u <= 0x7A;
  static bool _isCjk(int u) => (u >= 0x2E80 && u <= 0x9FFF) || (u >= 0xFF00 && u <= 0xFFEF) || (u >= 0x3000 && u <= 0x303F);

  /// Height of the tallest title line over all pages: level-1 headings are
  /// those close to it.
  static double headingHeight(List<PageInput> pages) {
    var h = 0.0;
    for (final p in pages) {
      for (final i in usefulRegions(p)) {
        if (p.regions[i].kind != RegionKind.title) continue;
        for (final l in p.lines) {
          if (p.regions[i].box.inflate(4).contains(l.bounds.center)) h = math.max(h, l.height);
        }
      }
    }
    return h;
  }
}
