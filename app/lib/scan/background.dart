import 'dart:isolate';
import 'dart:typed_data';

import 'edge_detector.dart';
import 'image_ops.dart';
import 'quad.dart';

// Every heavy image job runs through these top-level functions.
//
// Why top-level: a closure passed to Isolate.run is copied to the new
// isolate together with its whole captured scope. Inside a widget State
// method that scope often also holds `this` (because a sibling closure
// calls setState), and a State is not sendable, so Isolate.run fails.
// A top-level function's closure can only capture its own parameters.

Future<Uint8List> processInBackground(
  Uint8List src, {
  Quad? quad,
  ScanFilter filter = ScanFilter.enhance,
  int rotation = 0,
  int? maxSide,
}) =>
    Isolate.run(() => ImageOps.process(src, quad: quad, filter: filter, rotateQuarterTurns: rotation, maxSide: maxSide));

/// Full-size processed page plus its thumbnail.
Future<(Uint8List, Uint8List)> renderPageInBackground(Uint8List src, Quad? quad, ScanFilter filter, int rotation) =>
    Isolate.run(() {
      final proc = ImageOps.process(src, quad: quad, filter: filter, rotateQuarterTurns: rotation);
      return (proc, ImageOps.thumbnail(proc));
    });

Future<PreparedImage> prepareInBackground(Uint8List raw) => Isolate.run(() => ImageOps.prepare(raw));

Future<Quad?> detectLumaInBackground(Uint8List y, int width, int height, int bytesPerRow) =>
    Isolate.run(() => EdgeDetector.detectLuma(y, width, height, bytesPerRow));

Future<Uint8List> bgraToJpegInBackground(Uint8List bgra, int width, int height, {int quality = 95}) =>
    Isolate.run(() => ImageOps.bgraToJpeg(bgra, width, height, quality: quality));

Future<Uint8List> stitchInBackground(List<Uint8List> pages) => Isolate.run(() => ImageOps.stitchVertical(pages));

Future<Uint8List> blackOutInBackground(Uint8List src, List<List<(double, double)>> polygons) =>
    Isolate.run(() => ImageOps.blackOut(src, polygons));

/// Fallback when the JPEG header cannot be parsed: decode to get the size.
Future<(int, int)> jpegSizeInBackground(Uint8List src) => Isolate.run(() => ImageOps.sizeOf(src));

Future<Uint8List> rgbaToJpegInBackground(Uint8List rgba, int width, int height) =>
    Isolate.run(() => ImageOps.rgbaToJpeg(rgba, width, height));

Future<Uint8List> recompressInBackground(Uint8List src, int maxSide, int quality) =>
    Isolate.run(() => ImageOps.recompress(src, maxSide, quality));
