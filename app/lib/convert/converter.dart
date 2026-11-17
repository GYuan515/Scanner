import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import '../data/db.dart';
import '../data/page_store.dart';
import '../ocr/ocr_queue.dart';
import '../ocr/ocr_result.dart';
import '../ocr/ocr_service.dart';
import '../scan/background.dart';
import '../scan/image_ops.dart';
import 'doc_model.dart';
import 'docx_writer.dart';
import 'layout.dart';
import 'pdf_text.dart';
import 'table.dart';
import 'xlsx_writer.dart';

typedef Progress = void Function(String message);

/// Scanned documents or PDF files -> Word / Excel.
class DocumentConverter {
  DocumentConverter({required this.layout, required this.ocr});
  final LayoutEngine layout;
  final OcrEngine ocr;

  /// Layout, tables and figure crops for one page image whose text lines
  /// are already known.
  Future<PageInput> analyze(String imagePath, int width, int height, List<OcrLine> lines) async {
    final regions = await layout.layout(imagePath);
    final page = PageInput(width: width, height: height, lines: lines, regions: regions);
    for (final i in PageAnalyzer.usefulRegions(page)) {
      final r = regions[i];
      switch (r.kind) {
        case RegionKind.table:
          final grid = await layout.table(imagePath, r.box);
          if (grid.cells.isEmpty) break;
          TableDecoder.fill(grid, lines.where((l) => r.box.inflate(4).contains(l.bounds.center)));
          page.tables[i] = grid;
        case RegionKind.figure:
        case RegionKind.equation:
          page.crops[i] = await cropJpegInBackground(imagePath, r.box);
        default:
          break;
      }
    }
    return page;
  }

  /// Pages of a scanned document (their recognized text is read first if
  /// missing).
  Future<List<PageInput>> fromScans(List<ScanPage> pages, PageStore store, OcrQueue queue, Progress progress) async {
    final out = <PageInput>[];
    for (var i = 0; i < pages.length; i++) {
      progress('正在分析第 ${i + 1} / ${pages.length} 页…');
      final (pg, text) = await _pageText(pages[i], store, queue);
      // Text and image must belong to the same version of the page.
      final path = store.file(pg.processedFile).path;
      out.add(await analyze(path, text.width, text.height, text.lines.toList()));
    }
    return out;
  }

  /// The page's current version and its text. readNow returns null when
  /// the page changed (re-crop, filter) or already had text meanwhile, so
  /// the row is reloaded and read again from its current image.
  Future<(ScanPage, OcrResult)> _pageText(ScanPage page, PageStore store, OcrQueue queue) async {
    var pg = page;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (pg.ocrJson != null) return (pg, OcrResult.fromJsonString(pg.ocrJson!));
      final r = await queue.readNow(pg);
      final fresh = await store.db.pageById(pg.id);
      if (fresh == null) throw StateError('页面已被删除');
      if (r != null && fresh.processedFile == pg.processedFile) return (fresh, r);
      pg = fresh;
    }
    // Still changing: read it directly, from the same file analyzed next.
    return (pg, await ocr.recognizeFile(store.file(pg.processedFile).path));
  }

  /// Pages of a PDF: rendered at 150 dpi for the layout model; text from
  /// the PDF itself when it has a text layer, else from OCR.
  Future<List<PageInput>> fromPdf(PdfDocument doc, Directory work, Progress progress) async {
    final out = <PageInput>[];
    for (var i = 0; i < doc.pages.length; i++) {
      progress('正在分析第 ${i + 1} / ${doc.pages.length} 页…');
      final page = doc.pages[i];
      var scale = 150 / 72;
      final longest = math.max(page.width, page.height) * scale;
      if (longest > 3000) scale *= 3000 / longest;
      final w = (page.width * scale).round(), h = (page.height * scale).round();
      final img = await page.render(fullWidth: w.toDouble(), fullHeight: h.toDouble(), backgroundColor: 0xffffffff);
      if (img == null) throw StateError('第 ${i + 1} 页渲染失败');
      final file = File(p.join(work.path, 'page_${i + 1}.jpg'));
      try {
        // Top-level helper with plain bytes: a closure here would carry this
        // method's whole scope (and the native image) into the isolate.
        final px = img.pixels, iw = img.width, ih = img.height;
        await file.writeAsBytes(await bgraToJpegInBackground(px, iw, ih, quality: 90), flush: true);
      } finally {
        img.dispose();
      }
      // Rotated pages: PDF text boxes are in unrotated page space; use OCR.
      var lines = page.rotation == PdfPageRotation.none ? await pdfTextLines(page, scale) : const <OcrLine>[];
      if (!hasTextLayer(lines)) lines = (await ocr.recognizeFile(file.path)).lines.toList();
      out.add(await analyze(file.path, w, h, lines));
    }
    return out;
  }

  /// All pages as one Word document, a page break between source pages.
  static Future<Uint8List> toDocx(List<PageInput> pages, {String title = ''}) {
    final heading = PageAnalyzer.headingHeight(pages);
    final blocks = <DocBlock>[];
    for (var i = 0; i < pages.length; i++) {
      if (i > 0) blocks.add(const PageBreakBlock());
      blocks.addAll(PageAnalyzer.blocks(pages[i], headingHeight: heading));
    }
    return _docxInBackground(blocks, title);
  }

  /// One sheet per recognized table. Without any table, the text of each
  /// page as rows (one cell per text box), so the result is never empty.
  static Future<(Uint8List, int)> toXlsx(List<PageInput> pages) {
    final sheets = <SheetData>[];
    for (var i = 0; i < pages.length; i++) {
      final tables = pages[i].tables.entries.toList()..sort((a, b) => pages[i].regions[a.key].box.top.compareTo(pages[i].regions[b.key].box.top));
      for (var k = 0; k < tables.length; k++) {
        sheets.add(SheetData(pages.length == 1 ? '表${k + 1}' : '第${i + 1}页 表${k + 1}', tables[k].value));
      }
    }
    final tableCount = sheets.length;
    if (sheets.isEmpty) {
      for (var i = 0; i < pages.length; i++) {
        final grid = textGrid(pages[i].lines);
        if (grid.cells.isNotEmpty) sheets.add(SheetData('第${i + 1}页 文字', grid));
      }
    }
    if (sheets.isEmpty) throw const FormatException('没有识别到表格或文字');
    return _xlsxInBackground(sheets, tableCount);
  }

  /// Text rows as a grid: one row per text line, one cell per text box.
  static TableGrid textGrid(List<OcrLine> lines) {
    final rows = OcrResult.arrange(lines);
    final cells = <TableCell>[];
    var cols = 0;
    for (var r = 0; r < rows.length; r++) {
      for (var c = 0; c < rows[r].length; c++) {
        cells.add(TableCell(r, c, 1, 1, rows[r][c].bounds)..text = rows[r][c].text.trim());
      }
      cols = math.max(cols, rows[r].length);
    }
    return TableGrid(rows.length, cols, cells);
  }
}

// Top-level so the isolate closures carry only their arguments, not the
// calling method's scope (which holds every page).
Future<Uint8List> _docxInBackground(List<DocBlock> blocks, String title) =>
    Isolate.run(() => DocxWriter.write(blocks, title: title));

Future<(Uint8List, int)> _xlsxInBackground(List<SheetData> sheets, int tables) =>
    Isolate.run(() => (XlsxWriter.write(sheets), tables));

/// Crops [box] out of the image at [path] as a JPEG: (bytes, width, height),
/// at most 1600 px on the long side (plenty for a figure in Word).
Future<(Uint8List, int, int)> cropJpegInBackground(String path, Rect box) {
  final l = box.left, t = box.top, r = box.right, b = box.bottom;
  return Isolate.run(() {
    final img = cv.imread(path, flags: cv.IMREAD_COLOR);
    try {
      final x = l.floor().clamp(0, img.cols - 1), y = t.floor().clamp(0, img.rows - 1);
      final w = (r.ceil() - x).clamp(1, img.cols - x), h = (b.ceil() - y).clamp(1, img.rows - y);
      final roi = img.region(cv.Rect(x, y, w, h));
      cv.Mat? small;
      try {
        final s = 1600 / math.max(w, h);
        if (s < 1) small = cv.resize(roi, ((w * s).round(), (h * s).round()), interpolation: cv.INTER_AREA);
        final out = small ?? roi;
        return (ImageOps.encodeJpeg(out, quality: 90), out.cols, out.rows);
      } finally {
        small?.dispose();
        roi.dispose();
      }
    } finally {
      img.dispose();
    }
  });
}
