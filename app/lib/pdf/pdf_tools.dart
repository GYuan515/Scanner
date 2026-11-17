import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';

import '../data/exporter.dart';
import '../scan/background.dart';
import 'pdf_crypto.dart';

/// Page range text like "1-3, 5, 8-" (1-based, inclusive; "8-" = to the
/// end) -> page numbers in the given order. Throws [FormatException] with
/// a message for the user.
List<int> parsePageRanges(String spec, int pageCount) {
  final out = <int>[];
  final parts = spec.replaceAll('，', ',').replaceAll('－', '-').replaceAll('—', '-').split(',');
  for (final raw in parts) {
    final part = raw.trim();
    if (part.isEmpty) continue;
    final m = RegExp(r'^(\d*)\s*-\s*(\d*)$').firstMatch(part);
    int a, b;
    if (m != null) {
      a = m[1]!.isEmpty ? 1 : int.parse(m[1]!);
      b = m[2]!.isEmpty ? pageCount : int.parse(m[2]!);
    } else if (RegExp(r'^\d+$').hasMatch(part)) {
      a = b = int.parse(part);
    } else {
      throw FormatException('看不懂“$part”，请写成 1-3,5 这样的格式');
    }
    if (a < 1 || b < 1 || a > pageCount || b > pageCount) {
      throw FormatException('“$part”超出了页数范围（共 $pageCount 页）');
    }
    final step = a <= b ? 1 : -1;
    for (var p = a; p != b + step; p += step) {
      out.add(p);
    }
  }
  if (out.isEmpty) throw const FormatException('没有选中任何页');
  return out;
}

/// Splits 1..pageCount into groups of [every] pages.
List<List<int>> splitEvery(int pageCount, int every) {
  if (every < 1) throw const FormatException('每份至少 1 页');
  return [
    for (var s = 1; s <= pageCount; s += every) [for (var p = s; p <= math.min(pageCount, s + every - 1); p++) p],
  ];
}

/// A page to put into a new PDF: [page] (1-based) of [doc], turned by
/// [quarterTurns] clockwise on top of its current rotation.
typedef PagePick = ({PdfDocument doc, int page, int quarterTurns});

/// Page-level tools for existing PDF files, on PDFium via pdfrx. Pages are
/// copied as they are, so text stays text and nothing is re-rendered,
/// except for [compress] and [toImages], which render on purpose.
class PdfTools {
  /// Opens a PDF; [password] is tried for encrypted files. A wrong or
  /// missing password throws [PdfPasswordException].
  static Future<PdfDocument> open(String path, {String? password}) => PdfDocument.openFile(
        path,
        passwordProvider: _once(password),
        firstAttemptByEmptyPassword: password == null,
      );

  static Future<PdfDocument> openData(Uint8List data, String name, {String? password}) => PdfDocument.openData(
        data,
        sourceName: name,
        passwordProvider: _once(password),
        firstAttemptByEmptyPassword: password == null,
      );

  /// pdfrx asks the provider again after every wrong password until it
  /// returns null; answering with the same password forever would loop.
  static PdfPasswordProvider? _once(String? password) {
    if (password == null) return null;
    var given = false;
    return () {
      if (given) return null;
      given = true;
      return password;
    };
  }

  static PdfPage _pick(PagePick p) {
    final page = p.doc.pages[p.page - 1];
    final turns = p.quarterTurns % 4;
    return turns == 0 ? page : page.rotatedBy(PdfPageRotation.values[turns]);
  }

  /// New PDF from [picks], in order. Covers extract, delete (pick the
  /// others), reorder, rotate and merge (picks from several documents).
  static Future<Uint8List> assemble(List<PagePick> picks) async {
    if (picks.isEmpty) throw const FormatException('没有页面');
    final out = await PdfDocument.createNew(sourceName: 'out.pdf');
    try {
      out.pages = [for (final p in picks) _pick(p)];
      return await out.encodePdf();
    } finally {
      await out.dispose();
    }
  }

  static Future<Uint8List> merge(List<PdfDocument> docs) => assemble([
        for (final d in docs)
          for (var i = 1; i <= d.pages.length; i++) (doc: d, page: i, quarterTurns: 0),
      ]);

  static Future<List<Uint8List>> split(PdfDocument doc, List<List<int>> groups) async => [
        for (final g in groups) await assemble([for (final p in g) (doc: doc, page: p, quarterTurns: 0)]),
      ];

  /// The same document without its password.
  static Future<Uint8List> decrypt(PdfDocument doc) => doc.encodePdf(removeSecurity: true);

  /// Renders pages to JPEG at [dpi]; null [pages] = all.
  static Future<List<Uint8List>> toImages(PdfDocument doc, {int dpi = 200, List<int>? pages, int quality = 92}) async {
    final out = <Uint8List>[];
    for (final n in pages ?? [for (var i = 1; i <= doc.pages.length; i++) i]) {
      out.add(await _renderJpeg(doc.pages[n - 1], dpi, quality));
    }
    return out;
  }

  static Future<Uint8List> _renderJpeg(PdfPage page, int dpi, int quality) async {
    // Cap very large pages (posters) so one page cannot exhaust memory.
    var scale = dpi / 72;
    final longest = math.max(page.width, page.height) * scale;
    if (longest > 6000) scale *= 6000 / longest;
    final w = (page.width * scale).round(), h = (page.height * scale).round();
    final img = await page.render(fullWidth: w.toDouble(), fullHeight: h.toDouble(), backgroundColor: 0xffffffff);
    if (img == null) throw StateError('第 ${page.pageNumber} 页渲染失败');
    try {
      return await bgraToJpegInBackground(img.pixels, img.width, img.height, quality: quality);
    } finally {
      img.dispose();
    }
  }

  /// Smaller file by re-rendering every page as a JPEG at [dpi]. Page sizes
  /// stay the same; text becomes part of the image (fine for scans).
  static Future<Uint8List> compress(PdfDocument doc, {int dpi = 110, int quality = 65, String? password}) async {
    final pages = <(Uint8List, double, double)>[];
    for (final page in doc.pages) {
      // page.width/height already include the page's rotation.
      pages.add((await _renderJpeg(page, dpi, quality), page.width, page.height));
    }
    // Building (and the password key setup, which is slow in pure Dart)
    // happens off the UI isolate.
    return Isolate.run(() => _imagePdf(pages, password));
  }

  static Future<Uint8List> _imagePdf(List<(Uint8List, double, double)> pages, String? password) {
    final out = pw.Document(compress: true);
    if (password != null && password.isNotEmpty) out.document.encryption = Aes256Encryption(out.document, password);
    for (final (jpg, w, h) in pages) {
      out.addPage(pw.Page(
        pageFormat: PdfPageFormat(w, h),
        margin: pw.EdgeInsets.zero,
        build: (_) => pw.Image(pw.MemoryImage(jpg), fit: pw.BoxFit.fill),
      ));
    }
    return out.save();
  }

  /// Photos / images to a PDF, one per page, with the export options
  /// (page size, margins, quality, password).
  static Future<Uint8List> imagesToPdf(List<Uint8List> images, PdfOptions options) async {
    final pages = <PdfPageInput>[];
    for (final raw in images) {
      // Applies EXIF orientation and caps the size like a scan import.
      final prepared = await prepareInBackground(raw);
      final q = options.quality;
      final bytes = q.maxSide == null ? prepared.bytes : await recompressInBackground(prepared.bytes, q.maxSide!, q.jpeg!);
      pages.add(PdfPageInput(bytes, null, const [], prepared.width, prepared.height));
    }
    return Isolate.run(() => Exporter.pdfBytes(pages, options));
  }
}
