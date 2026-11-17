import 'dart:ui' show Offset, Rect;

import '../ocr/ocr_result.dart';

/// Ready-made patterns for sensitive data in recognized text.
enum RedactPreset {
  phone('手机号', r'(?<!\d)1[3-9]\d{9}(?!\d)'),
  idCard('身份证号', r'(?<![\dXx])\d{17}[\dXx](?![\dXx])'),
  // Not followed by X either, so the first 17 digits of an ID card ending
  // in X do not count as a card number.
  bankCard('银行卡号', r'(?<![\dXx])\d{4}(?:[ -]?\d{4}){2,3}(?:[ -]?\d{1,3})?(?![\dXx])'),
  email('邮箱', r'[\w.+-]+@[\w-]+(?:\.[\w-]+)+');

  const RedactPreset(this.label, this.pattern);
  final String label;
  final String pattern;

  RegExp get regex => RegExp(pattern);
}

/// A piece of recognized text to black out.
class RedactMatch {
  const RedactMatch(this.text, this.area, this.line);
  final String text;

  /// Image-pixel rectangle covering the matched characters.
  final Rect area;
  final OcrLine line;
}

/// Finds [pattern] in every OCR line and estimates where the matched
/// characters sit inside the line box.
///
/// OCR only gives a box per line, so character positions are interpolated
/// by width: CJK and full-width characters count as 1, others as 0.55
/// (digits and Latin letters in typical fonts). The area is padded so a
/// slightly wrong estimate still covers the characters.
List<RedactMatch> findInLines(Iterable<OcrLine> lines, RegExp pattern) {
  final out = <RedactMatch>[];
  for (final line in lines) {
    final text = line.text;
    for (final m in pattern.allMatches(text)) {
      if (m.end <= m.start) continue;
      out.add(RedactMatch(m[0]!, spanArea(line, m.start, m.end), line));
    }
  }
  return out;
}

/// Literal search (case-insensitive), for a keyword typed by the user.
List<RedactMatch> findKeyword(Iterable<OcrLine> lines, String keyword) {
  final k = keyword.trim();
  if (k.isEmpty) return const [];
  return findInLines(lines, RegExp(RegExp.escape(k), caseSensitive: false));
}

double _weight(int rune) {
  if (rune >= 0x2E80 && rune <= 0x9FFF) return 1; // CJK
  if (rune >= 0xAC00 && rune <= 0xD7AF) return 1; // Hangul
  if (rune >= 0xFF00 && rune <= 0xFFEF) return 1; // full-width forms
  if (rune >= 0x3000 && rune <= 0x303F) return 1; // CJK punctuation
  if (rune == 0x20) return 0.35;
  return 0.55;
}

/// Image-pixel area of characters [start, end) of [line] (UTF-16 indices).
Rect spanArea(OcrLine line, int start, int end) {
  final units = line.text.codeUnits;
  double w(int from, int to) {
    var s = 0.0;
    for (final r in String.fromCharCodes(units.sublist(from, to)).runes) {
      s += _weight(r);
    }
    return s;
  }

  final total = w(0, units.length);
  if (total == 0) return line.bounds;
  final a = w(0, start) / total, b = w(0, end) / total;
  final box = line.box; // tl, tr, br, bl
  Offset lerp(Offset p, Offset q, double t) => p + (q - p) * t;
  final pts = [lerp(box[0], box[1], a), lerp(box[0], box[1], b), lerp(box[3], box[2], b), lerp(box[3], box[2], a)];
  var l = pts.first.dx, t = pts.first.dy, r = l, bt = t;
  for (final p in pts) {
    if (p.dx < l) l = p.dx;
    if (p.dx > r) r = p.dx;
    if (p.dy < t) t = p.dy;
    if (p.dy > bt) bt = p.dy;
  }
  final pad = line.height * 0.15;
  return Rect.fromLTRB(l - pad, t - pad, r + pad, bt + pad);
}
