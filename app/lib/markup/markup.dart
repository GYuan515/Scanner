import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'geometry.dart';

enum MarkupKind {
  ink, // freehand stroke
  highlight,
  underline,
  strike,
  text, // text box
  note, // sticky note: an icon on the page, the text in a popup / PDF note
  image; // signature or stamp

  static MarkupKind byName(String n) => values.firstWhere((k) => k.name == n, orElse: () => ink);
}

/// One annotation, in processed-image pixels.
class MarkupItem {
  const MarkupItem({
    required this.kind,
    this.color = 0xFFE53935,
    this.width = 6,
    this.points = const [],
    this.rect = Rect.zero,
    this.text = '',
    this.angle = 0,
    this.image,
  });

  final MarkupKind kind;

  /// ARGB.
  final int color;

  /// Stroke width (ink, underline, strike) or font size (text), in pixels.
  final double width;

  /// Ink stroke.
  final List<Offset> points;

  /// highlight / underline / strike / text / image: the box (rotation
  /// about its centre by [angle]); note: only the top-left matters.
  final Rect rect;

  /// text box contents or note text.
  final String text;

  /// Radians, clockwise, for text and image.
  final double angle;

  /// Signature file name (in the signatures directory).
  final String? image;

  bool get isRectKind => kind != MarkupKind.ink;

  MarkupItem copyWith({Rect? rect, List<Offset>? points, String? text, double? angle, double? width, int? color}) =>
      MarkupItem(
        kind: kind,
        color: color ?? this.color,
        width: width ?? this.width,
        points: points ?? this.points,
        rect: rect ?? this.rect,
        text: text ?? this.text,
        angle: angle ?? this.angle,
        image: image,
      );

  /// Same item pointing at another image file (document copies).
  MarkupItem withImage(String file) => MarkupItem(
        kind: kind,
        color: color,
        width: width,
        points: points,
        rect: rect,
        text: text,
        angle: angle,
        image: file,
      );

  bool get isFinite {
    bool ok(double v) => v.isFinite;
    return ok(width) &&
        ok(angle) &&
        ok(rect.left) &&
        ok(rect.top) &&
        ok(rect.right) &&
        ok(rect.bottom) &&
        points.every((p) => ok(p.dx) && ok(p.dy));
  }

  /// Rough bounds for hit testing and remapping.
  Rect get bounds {
    if (kind == MarkupKind.ink) {
      if (points.isEmpty) return Rect.zero;
      var l = points.first.dx, t = points.first.dy, r = l, b = t;
      for (final p in points) {
        l = math.min(l, p.dx);
        t = math.min(t, p.dy);
        r = math.max(r, p.dx);
        b = math.max(b, p.dy);
      }
      return Rect.fromLTRB(l, t, r, b).inflate(width / 2);
    }
    return rect;
  }

  /// Whether a tap at [p] (image pixels) with [slop] touches this item.
  bool hit(Offset p, double slop) {
    if (kind == MarkupKind.ink) {
      for (var i = 0; i < points.length; i++) {
        final a = points[i], b = i + 1 < points.length ? points[i + 1] : a;
        if (_distToSegment(p, a, b) <= slop + width / 2) return true;
      }
      return false;
    }
    if (angle != 0) {
      // Rotate the tap into the item's frame.
      final c = rect.center, d = p - c;
      final cos = math.cos(-angle), sin = math.sin(-angle);
      p = c + Offset(d.dx * cos - d.dy * sin, d.dx * sin + d.dy * cos);
    }
    return rect.inflate(slop).contains(p);
  }

  static double _distToSegment(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
    if (len2 == 0) return (p - a).distance;
    final t = (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / len2).clamp(0.0, 1.0);
    return (p - (a + ab * t)).distance;
  }

  /// This item on the same photo after a re-crop or rotation.
  MarkupItem remapped(PageGeometry from, PageGeometry to) {
    switch (kind) {
      case MarkupKind.ink:
        final s = from.remapScale(bounds.center, to);
        return copyWith(points: [for (final p in points) from.remap(p, to)], width: width * s);
      case MarkupKind.text:
      case MarkupKind.image:
      case MarkupKind.note:
        // Keep the shape; move the centre, scale, and turn with the page.
        final c = from.remap(rect.center, to);
        final s = from.remapScale(rect.center, to);
        final turn = ((to.rotation - from.rotation) % 4) * math.pi / 2;
        final w = rect.width * s, h = rect.height * s;
        return copyWith(
          rect: Rect.fromCenter(center: c, width: w, height: h),
          angle: kind == MarkupKind.note ? 0 : _norm(angle + turn),
          width: kind == MarkupKind.text ? width * s : width,
        );
      case MarkupKind.highlight:
      case MarkupKind.underline:
      case MarkupKind.strike:
        return copyWith(rect: from.remapRect(rect, to), width: width * from.remapScale(rect.center, to));
    }
  }

  static double _norm(double a) {
    final t = a % (2 * math.pi);
    return t > math.pi ? t - 2 * math.pi : t;
  }

  Map<String, dynamic> toJson() => {
        'k': kind.name,
        'c': color,
        'w': _r(width),
        if (points.isNotEmpty) 'p': [for (final p in points) ...[_r(p.dx), _r(p.dy)]],
        if (kind != MarkupKind.ink) 'r': [_r(rect.left), _r(rect.top), _r(rect.right), _r(rect.bottom)],
        if (text.isNotEmpty) 't': text,
        if (angle != 0) 'a': angle,
        if (image != null) 'i': image,
      };

  factory MarkupItem.fromJson(Map<String, dynamic> j) {
    final p = (j['p'] as List?)?.cast<num>() ?? const <num>[];
    final r = (j['r'] as List?)?.cast<num>();
    return MarkupItem(
      kind: MarkupKind.byName(j['k'] as String),
      color: j['c'] as int,
      width: (j['w'] as num).toDouble(),
      points: [for (var i = 0; i + 1 < p.length; i += 2) Offset(p[i].toDouble(), p[i + 1].toDouble())],
      rect: r == null ? Rect.zero : Rect.fromLTRB(r[0].toDouble(), r[1].toDouble(), r[2].toDouble(), r[3].toDouble()),
      text: j['t'] as String? ?? '',
      angle: (j['a'] as num?)?.toDouble() ?? 0,
      image: j['i'] as String?,
    );
  }

  static double _r(double v) => (v * 10).roundToDouble() / 10;
}

/// All annotations of a page. Immutable: edits return a new value, which
/// keeps undo a simple stack.
class PageMarkup {
  const PageMarkup(this.items);
  static const empty = PageMarkup([]);

  final List<MarkupItem> items;
  bool get isEmpty => items.isEmpty;

  PageMarkup add(MarkupItem i) => PageMarkup([...items, i]);
  PageMarkup replaceAt(int index, MarkupItem i) => PageMarkup([...items]..[index] = i);
  PageMarkup removeAt(int index) => PageMarkup([...items]..removeAt(index));

  /// Topmost item under [p], or -1.
  int hitTest(Offset p, double slop) {
    for (var i = items.length - 1; i >= 0; i--) {
      if (items[i].hit(p, slop)) return i;
    }
    return -1;
  }

  /// Markup on the same photo after a re-crop or rotation. Items that land
  /// on the far side of a strongly tilted crop (the projective map blows up
  /// there) are dropped instead of being stored as NaN / infinity.
  PageMarkup remapped(PageGeometry from, PageGeometry to) => from.sameAs(to)
      ? this
      : PageMarkup([
          for (final i in items)
            if (i.remapped(from, to) case final r when r.isFinite) r,
        ]);

  Iterable<String> get imageFiles => items.map((i) => i.image).whereType<String>();

  String? toJsonString() => items.isEmpty ? null : jsonEncode([for (final i in items) i.toJson()]);

  static PageMarkup parse(String? s) => s == null || s.isEmpty
      ? empty
      : PageMarkup([for (final j in jsonDecode(s) as List) MarkupItem.fromJson(j as Map<String, dynamic>)]);
}
