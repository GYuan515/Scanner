import 'dart:convert';

/// Document-wide watermark, drawn on every page when reading and exporting.
class Watermark {
  const Watermark({
    this.text = '',
    this.image,
    this.color = 0xFF9E9E9E,
    this.opacity = 0.25,
    this.angle = -30,
    this.size = 0.06,
    this.tiled = true,
  });

  /// Text watermark; ignored when [image] is set.
  final String text;

  /// Image watermark file name (in the watermarks directory).
  final String? image;

  /// ARGB; the alpha is replaced by [opacity].
  final int color;
  final double opacity;

  /// Degrees, counter-clockwise positive like most editors show it.
  final double angle;

  /// Text height (or image width) as a fraction of the page width.
  final double size;

  /// Repeat across the page instead of one mark in the centre.
  final bool tiled;

  bool get isEmpty => image == null && text.trim().isEmpty;

  Watermark copyWith({
    String? text,
    String? image,
    bool clearImage = false,
    int? color,
    double? opacity,
    double? angle,
    double? size,
    bool? tiled,
  }) =>
      Watermark(
        text: text ?? this.text,
        image: clearImage ? null : (image ?? this.image),
        color: color ?? this.color,
        opacity: opacity ?? this.opacity,
        angle: angle ?? this.angle,
        size: size ?? this.size,
        tiled: tiled ?? this.tiled,
      );

  String? toJsonString() => isEmpty
      ? null
      : jsonEncode({
          't': text,
          if (image != null) 'i': image,
          'c': color,
          'o': opacity,
          'a': angle,
          's': size,
          'tl': tiled,
        });

  static Watermark? parse(String? s) {
    if (s == null || s.isEmpty) return null;
    final j = jsonDecode(s) as Map<String, dynamic>;
    final w = Watermark(
      text: j['t'] as String? ?? '',
      image: j['i'] as String?,
      color: j['c'] as int? ?? 0xFF9E9E9E,
      opacity: (j['o'] as num?)?.toDouble() ?? 0.25,
      angle: (j['a'] as num?)?.toDouble() ?? -30,
      size: (j['s'] as num?)?.toDouble() ?? 0.06,
      tiled: j['tl'] as bool? ?? true,
    );
    return w.isEmpty ? null : w;
  }
}
