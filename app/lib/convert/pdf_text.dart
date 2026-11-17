import 'dart:ui' show Rect;

import 'package:pdfrx/pdfrx.dart';

import '../ocr/ocr_result.dart';

/// Text lines of a PDF page that already has text (not a scan), mapped to
/// a page image rendered at [scale] pixels per point. Empty for scans.
Future<List<OcrLine>> pdfTextLines(PdfPage page, double scale) async {
  final text = await page.loadText();
  if (text == null) return const [];
  return linesFromChars(text.fullText, text.charRects, page.height, scale);
}

/// Groups characters into lines: a new line at a line break, when the next
/// character sits on another baseline or jumps back left, and at a wide
/// horizontal gap (table cells typed on one baseline stay separate).
///
/// PDFium gives one rect per character but pdfrx builds [fullText] from
/// code points, so characters outside the BMP (emoji, CJK Ext-B) take two
/// UTF-16 units. Rects are therefore matched per rune; if the counts do
/// not line up either way, nothing is returned and the caller falls back
/// to OCR rather than misplace every following box.
List<OcrLine> linesFromChars(String fullText, List<PdfRect> rects, double pageHeight, double scale) {
  final runes = fullText.runes.toList();
  final List<String> chars;
  if (rects.length == runes.length) {
    chars = [for (final r in runes) String.fromCharCode(r)];
  } else if (rects.length == fullText.length) {
    chars = [for (var i = 0; i < fullText.length; i++) fullText[i]];
  } else {
    return const [];
  }

  final out = <OcrLine>[];
  final sb = StringBuffer();
  Rect? box;
  Rect? lastGlyph;

  void flush() {
    final t = sb.toString().trim();
    if (t.isNotEmpty && box != null) {
      final b = box!;
      out.add(OcrLine([b.topLeft, b.topRight, b.bottomRight, b.bottomLeft], t, 1));
    }
    sb.clear();
    box = null;
    lastGlyph = null;
  }

  for (var i = 0; i < chars.length; i++) {
    final ch = chars[i];
    if (ch == '\n' || ch == '\r') {
      flush();
      continue;
    }
    final r = rects[i];
    // PDF points (y up) -> image pixels (y down).
    final img = Rect.fromLTRB(r.left * scale, (pageHeight - r.top) * scale, r.right * scale, (pageHeight - r.bottom) * scale);
    final visible = ch.trim().isNotEmpty && img.width >= 0 && img.height > 0;
    final cur = box;
    if (visible && cur != null && cur.height > 0) {
      final overlap = (cur.bottom < img.bottom ? cur.bottom : img.bottom) - (cur.top > img.top ? cur.top : img.top);
      final h = cur.height < img.height ? cur.height : img.height;
      final last = lastGlyph;
      final gap = last == null ? 0.0 : img.left - last.right;
      if (overlap < h * 0.3 || img.left < cur.left - h || gap > h * 1.5) flush();
    }
    sb.write(ch);
    if (visible) {
      box = box == null ? img : box!.expandToInclude(img);
      lastGlyph = img;
    }
  }
  flush();
  return out;
}

/// Whether a page has a real text layer worth using instead of OCR.
bool hasTextLayer(List<OcrLine> lines) => lines.fold<int>(0, (s, l) => s + l.text.replaceAll(RegExp(r'\s'), '').length) >= 10;
