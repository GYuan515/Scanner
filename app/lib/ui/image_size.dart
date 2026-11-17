import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart' show Size;

/// Pixel size of an encoded image file, without decoding the pixels.
Future<Size> imageSizeOf(String path) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(await File(path).readAsBytes());
  ui.ImageDescriptor? desc;
  try {
    desc = await ui.ImageDescriptor.encoded(buffer);
    return Size(desc.width.toDouble(), desc.height.toDouble());
  } finally {
    desc?.dispose();
    buffer.dispose();
  }
}
