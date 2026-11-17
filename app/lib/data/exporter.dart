import 'dart:convert';
import 'dart:isolate';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';
import 'package:vector_math/vector_math_64.dart' show Matrix4;

import 'db.dart';
import 'page_store.dart';
import '../markup/compositor.dart';
import '../markup/geometry.dart' show jpegSize;
import '../pdf/pdf_crypto.dart';
import '../markup/markup.dart';
import '../markup/watermark.dart';
import '../ocr/ocr_result.dart';
import '../scan/background.dart';

enum PdfPageSize {
  fit('原尺寸'),
  a4('A4'),
  letter('Letter');

  const PdfPageSize(this.label);
  final String label;
}

enum PdfMargin {
  none('无', 0),
  small('窄', 18), // 0.25 inch
  normal('标准', 36); // 0.5 inch

  const PdfMargin(this.label, this.points);
  final String label;

  /// In PDF points (1/72 inch).
  final double points;
}

/// Image recompression for smaller files.
enum PdfQuality {
  original('原图', null, null),
  high('高', 2400, 85),
  medium('中', 1800, 72),
  small('小', 1200, 60);

  const PdfQuality(this.label, this.maxSide, this.jpeg);
  final String label;

  /// Longest image side in pixels; null keeps the image as is.
  final int? maxSide;
  final int? jpeg;
}

class PdfOptions {
  const PdfOptions({
    this.size = PdfPageSize.a4,
    this.margin = PdfMargin.none,
    this.searchable = true,
    this.quality = PdfQuality.original,
    this.password,
  });
  final PdfPageSize size;
  final PdfMargin margin;

  /// Adds the recognized text as an invisible layer, so the PDF can be
  /// searched and its text selected and copied.
  final bool searchable;

  final PdfQuality quality;

  /// Open password (AES-256); null or empty = no protection.
  final String? password;

  bool get encrypted => password != null && password!.isNotEmpty;

  PdfOptions copyWith({PdfQuality? quality, String? password, bool clearPassword = false}) => PdfOptions(
        size: size,
        margin: margin,
        searchable: searchable,
        quality: quality ?? this.quality,
        password: clearPassword ? null : (password ?? this.password),
      );
}

/// TrueType fonts for the invisible text layer, loaded from the assets on
/// the UI isolate (asset loading is not available inside Isolate.run).
/// Only the glyphs actually used end up in the PDF.
class PdfFonts {
  const PdfFonts(this.latin, this.cjk);

  /// Roboto: Latin, Greek, Cyrillic, digits and punctuation.
  final Uint8List latin;

  /// Droid Sans Fallback: CJK; has no Latin glyphs at all.
  final Uint8List cjk;

  static Future<PdfFonts> load() async {
    Future<Uint8List> read(String name) async {
      final d = await rootBundle.load('assets/fonts/$name');
      return d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes);
    }

    return PdfFonts(await read('Roboto-Regular.ttf'), await read('DroidSansFallbackFull.ttf'));
  }
}

/// One page to export: the page image (markup already burned in), its OCR
/// JSON for the text layer, and sticky notes to add as PDF annotations.
class PdfPageInput {
  const PdfPageInput(this.image, [this.ocrJson, this.notes = const [], this.width, this.height]);
  final Uint8List image;
  final String? ocrJson;

  /// (x, y, text): note position in page pixels ([width] x [height]).
  final List<(double, double, String)> notes;

  /// Size of the page in pixels before any recompression; it sets the page
  /// size for PdfPageSize.fit and the note positions. Defaults to the
  /// image's own size.
  final int? width;
  final int? height;
}

/// A PDF sticky note ("Text" annotation): an icon that opens [text].
class _NoteAnnotation extends pw.AnnotationBuilder {
  _NoteAnnotation(this.text);
  final String text;

  @override
  PdfAnnot build(pw.Context context, PdfRect? box) =>
      PdfAnnot(context.page, PdfAnnotText(rect: context.localToGlobal(box!), content: text, color: PdfColors.amber));
}

/// Builds PDFs / image sets from saved pages and hands them to the share
/// sheet or the system "save as" dialog.
class Exporter {
  Exporter(this.store, {this.watermark});
  final PageStore store;

  /// The document's watermark, drawn on every exported page.
  final Watermark? watermark;

  /// Exported page images: markup and watermark burned in where present.
  Future<List<Uint8List>> _images(List<ScanPage> pages) async {
    final c = PageCompositor(store);
    return [for (final pg in pages) await c.compose(pg, watermark: watermark)];
  }

  static List<(double, double, String)> _notes(ScanPage pg) => [
        for (final i in PageMarkup.parse(pg.markupJson).items)
          if (i.kind == MarkupKind.note && i.text.trim().isNotEmpty) (i.rect.left, i.rect.top, i.text),
      ];

  Future<Uint8List> buildPdf(List<ScanPage> pages, {PdfOptions options = const PdfOptions()}) async {
    final images = await _images(pages);
    final inputs = <PdfPageInput>[];
    for (var i = 0; i < pages.length; i++) {
      final size = jpegSize(images[i]);
      final q = options.quality;
      final bytes = q.maxSide == null ? images[i] : await recompressInBackground(images[i], q.maxSide!, q.jpeg!);
      inputs.add(PdfPageInput(bytes, pages[i].ocrJson, _notes(pages[i]), size?.$1, size?.$2));
    }
    final withText = options.searchable && inputs.any((p) => p.ocrJson != null);
    return _pdfInBackground(inputs, options, withText ? await PdfFonts.load() : null);
  }

  /// Builds the PDF from prepared page images (also used by the PDF
  /// toolbox for images -> PDF).
  static Future<Uint8List> pdfBytes(List<PdfPageInput> pages, PdfOptions options, [PdfFonts? fonts]) async {
    final doc = pw.Document(compress: true);
    if (options.encrypted) doc.document.encryption = Aes256Encryption(doc.document, options.password!);
    final m = options.margin.points;
    PdfTtfFont? latin, cjk;
    // Only when some page has text: a font object, once created, is written
    // into the file even if nothing uses it.
    if (fonts != null && options.searchable && pages.any((p) => p.ocrJson != null)) {
      latin = PdfTtfFont(doc.document, ByteData.sublistView(fonts.latin));
      cjk = PdfTtfFont(doc.document, ByteData.sublistView(fonts.cjk));
    }
    for (final page in pages) {
      final img = pw.MemoryImage(page.image);
      final w = (page.width ?? img.width!).toDouble(), h = (page.height ?? img.height!).toDouble();
      final PdfPageFormat format;
      switch (options.size) {
        case PdfPageSize.fit:
          // 150 dpi equivalent: pixels -> points, with the margin around it.
          format = PdfPageFormat(w * 72 / 150 + 2 * m, h * 72 / 150 + 2 * m);
        case PdfPageSize.a4:
          format = w > h ? PdfPageFormat.a4.landscape : PdfPageFormat.a4;
        case PdfPageSize.letter:
          format = w > h ? PdfPageFormat.letter.landscape : PdfPageFormat.letter;
      }
      final ocr = (latin != null && page.ocrJson != null) ? OcrResult.fromJsonString(page.ocrJson!) : null;
      // Points per image pixel where the image is drawn (contain, centred).
      final s = math.min((format.width - 2 * m) / w, (format.height - 2 * m) / h);
      doc.addPage(pw.Page(
        pageFormat: format,
        margin: pw.EdgeInsets.all(m),
        build: (_) => pw.Center(
          child: pw.AspectRatio(
            aspectRatio: w / h,
            child: pw.Stack(fit: pw.StackFit.expand, children: [
              pw.Image(img, fit: pw.BoxFit.fill),
              if (ocr != null && !ocr.isEmpty)
                pw.CustomPaint(painter: (canvas, size) => _paintText(canvas, size, ocr, latin!, cjk!)),
              for (final (x, y, text) in page.notes)
                pw.Positioned(
                  left: x * s,
                  top: y * s,
                  child: pw.Annotation(builder: _NoteAnnotation(text), child: pw.SizedBox(width: 18, height: 18)),
                ),
            ]),
          ),
        ),
      ));
    }
    return doc.save();
  }

  /// Draws every OCR line invisibly over its box. [size] is the drawn image
  /// in points; the canvas origin is its bottom-left corner. Each line is
  /// stretched horizontally to the box width so a selection in a viewer
  /// covers the words it copies.
  static void _paintText(PdfGraphics canvas, PdfPoint size, OcrResult ocr, PdfTtfFont latin, PdfTtfFont cjk) {
    if (ocr.width <= 0 || ocr.height <= 0) return;
    final sx = size.x / ocr.width, sy = size.y / ocr.height;
    for (final line in ocr.lines) {
      final text = line.text.trim();
      if (text.isEmpty) continue;
      final b = line.box;
      // Baseline runs along the bottom edge (bl -> br), in points, y up.
      final bl = PdfPoint(b[3].dx * sx, size.y - b[3].dy * sy);
      final br = PdfPoint(b[2].dx * sx, size.y - b[2].dy * sy);
      final width = math.sqrt(math.pow(br.x - bl.x, 2) + math.pow(br.y - bl.y, 2));
      final fontSize = line.height * sy * 0.85;
      if (width < 1 || fontSize < 1) continue;
      final runs = _runs(text, latin, cjk);
      final natural = runs.fold<double>(0, (s, r) => s + r.$1.stringMetrics(r.$2).advanceWidth * fontSize);
      if (natural <= 0) continue;
      final scale = width / natural;
      canvas
        ..saveContext()
        ..setTransform(Matrix4.identity()
          ..translateByDouble(bl.x, bl.y + line.height * sy * 0.15, 0, 1)
          ..rotateZ(math.atan2(br.y - bl.y, br.x - bl.x)));
      var x = 0.0;
      for (final (font, s) in runs) {
        // Tz (scale) stretches the glyphs but not the Td start position, so
        // x is in plain points. drawString takes a ratio and writes Tz * 100.
        canvas.drawString(font, fontSize, s, x, 0, scale: scale, mode: PdfTextRenderingMode.invisible);
        x += font.stringMetrics(s).advanceWidth * fontSize * scale;
      }
      canvas.restoreContext();
    }
  }

  /// Splits [text] into runs for the Latin font where it has the glyph and
  /// the CJK font everywhere else (its ToUnicode map keeps even glyph-less
  /// characters searchable).
  static List<(PdfTtfFont, String)> _runs(String text, PdfTtfFont latin, PdfTtfFont cjk) {
    final out = <(PdfTtfFont, String)>[];
    final sb = StringBuffer();
    PdfTtfFont? cur;
    for (final r in text.runes) {
      final f = latin.isRuneSupported(r) ? latin : cjk;
      if (cur != null && f != cur) {
        out.add((cur, sb.toString()));
        sb.clear();
      }
      cur = f;
      sb.writeCharCode(r);
    }
    if (cur != null) out.add((cur, sb.toString()));
    return out;
  }

  /// Recognized text of [pages], with page headers when there are several.
  static String plainText(List<ScanPage> pages) {
    if (pages.length == 1) return pages.single.ocrText ?? '';
    final sb = StringBuffer();
    for (var i = 0; i < pages.length; i++) {
      if (i > 0) sb.write('\n\n');
      sb.writeln('—— 第 ${i + 1} 页 ——');
      sb.write(pages[i].ocrText ?? '');
    }
    return sb.toString();
  }

  Future<void> shareText(String title, List<ScanPage> pages) async {
    final f = await _tempFile('${safeName(title)}.txt', Uint8List.fromList(utf8.encode(plainText(pages))));
    await SharePlus.instance.share(ShareParams(files: [XFile(f.path, mimeType: 'text/plain')], subject: title));
  }

  /// All pages stacked into one tall JPEG.
  Future<Uint8List> buildLongImage(List<ScanPage> pages) async {
    final images = await _images(pages);
    return stitchInBackground(images);
  }

  Future<void> shareLongImage(String title, List<ScanPage> pages) async {
    final f = await _tempFile('${safeName(title)}_长图.jpg', await buildLongImage(pages));
    await SharePlus.instance.share(ShareParams(files: [XFile(f.path, mimeType: 'image/jpeg')], subject: title));
  }

  Future<File> _tempFile(String name, Uint8List bytes) async {
    final dir = Directory(p.join((await getTemporaryDirectory()).path, 'export'));
    await dir.create(recursive: true);
    final f = File(p.join(dir.path, name));
    await f.writeAsBytes(bytes, flush: true);
    return f;
  }

  Future<void> sharePdf(String title, List<ScanPage> pages, {PdfOptions options = const PdfOptions()}) async {
    final bytes = await buildPdf(pages, options: options);
    final f = await _tempFile('${safeName(title)}.pdf', bytes);
    await SharePlus.instance.share(ShareParams(files: [XFile(f.path, mimeType: 'application/pdf')], subject: title));
  }

  Future<void> shareImages(String title, List<ScanPage> pages) async {
    final files = <XFile>[];
    final images = await _images(pages);
    for (var i = 0; i < pages.length; i++) {
      final f = await _tempFile('${safeName(title)}_${i + 1}.jpg', images[i]);
      files.add(XFile(f.path, mimeType: 'image/jpeg'));
    }
    await SharePlus.instance.share(ShareParams(files: files, subject: title));
  }

  static String safeName(String s) {
    final cleaned = s.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_').trim();
    return cleaned.isEmpty ? 'scan' : cleaned;
  }
}

// Top-level so the isolate closure captures only its arguments.
Future<Uint8List> _pdfInBackground(List<PdfPageInput> pages, PdfOptions options, PdfFonts? fonts) =>
    Isolate.run(() => Exporter.pdfBytes(pages, options, fonts));
