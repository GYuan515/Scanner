import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_zxing/flutter_zxing.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;

/// A QR code or barcode found in an image.
class FoundCode {
  const FoundCode(this.text, this.format);
  final String text;

  /// Human-readable symbology, e.g. "QR Code", "EAN-13".
  final String format;

  bool get isUrl => RegExp(r'^(https?://|www\.)', caseSensitive: false).hasMatch(text.trim());
}

/// Reads every QR code / barcode in the image file at [path].
/// zxing-cpp is called through FFI, so this runs fine in Isolate.run.
Future<List<FoundCode>> readCodesInBackground(String path) => Isolate.run(() => readCodes(path));

List<FoundCode> readCodes(String path) {
  final gray = cv.imread(path, flags: cv.IMREAD_GRAYSCALE);
  try {
    if (gray.isEmpty) throw const FormatException('无法读取图片');
    final m = gray.isContinuous ? gray : gray.clone();
    final bytes = Uint8List.fromList(m.data);
    if (!identical(m, gray)) m.dispose();
    return readCodesLuma(bytes, gray.cols, gray.rows);
  } finally {
    gray.dispose();
  }
}

/// [luma]: one byte per pixel, rows packed.
List<FoundCode> readCodesLuma(Uint8List luma, int width, int height) {
  final result = zx.readBarcodes(
    luma,
    DecodeParams(
      imageFormat: ImageFormat.lum,
      width: width,
      height: height,
      tryHarder: true,
      tryRotate: true,
      tryInverted: true,
      isMultiScan: true,
      // Scanned pages are large and codes on them small; the default 768
      // would shrink a printed QR code below what can be decoded.
      maxSize: 2400,
      maxNumberOfSymbols: 20,
    ),
  );
  final seen = <String>{};
  return [
    for (final c in result.codes)
      if (c.isValid && c.text != null && seen.add('${c.format}:${c.text}')) FoundCode(c.text!, (c.format ?? 0).name),
  ];
}
