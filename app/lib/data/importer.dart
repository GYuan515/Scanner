import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pdfrx/pdfrx.dart';

import '../scan/image_ops.dart';
import 'page_store.dart';
import '../scan/background.dart';

/// Result of an import: pages that loaded plus the names that did not.
class ImportResult {
  ImportResult(this.drafts, this.failed);
  final List<DraftPage> drafts;
  final List<String> failed;
}

/// Turns picked photos, image files and PDFs into [DraftPage]s.
class Importer {
  static const imageExtensions = ['jpg', 'jpeg', 'png', 'webp', 'bmp', 'heic', 'heif'];

  /// Photos get edge detection and the default "enhance" filter.
  static Future<DraftPage> fromImageBytes(Uint8List raw) async =>
      DraftPage.fromPrepared(await prepareInBackground(raw));

  /// PDF pages are already flat, so they keep the full page and the
  /// original colours. Rendered at [dpi], with the long side capped.
  static Future<List<DraftPage>> fromPdf(
    Uint8List data, {
    String? name,
    double dpi = 200,
    int maxSide = 3300,
    String? password,
  }) async {
    var given = false;
    final doc = await PdfDocument.openData(
      data,
      sourceName: name,
      // Answer once: pdfrx asks again after a wrong password until null.
      passwordProvider: password == null
          ? null
          : () {
              if (given) return null;
              given = true;
              return password;
            },
      firstAttemptByEmptyPassword: password == null,
    );
    try {
      final out = <DraftPage>[];
      for (final page in doc.pages) {
        var scale = dpi / 72;
        scale = math.min(scale, maxSide / math.max(page.width, page.height));
        final w = (page.width * scale).round(), h = (page.height * scale).round();
        final img = await page.render(fullWidth: w.toDouble(), fullHeight: h.toDouble(), backgroundColor: 0xffffffff);
        if (img == null) throw StateError('第 ${page.pageNumber} 页渲染失败');
        final pixels = img.pixels, iw = img.width, ih = img.height;
        final jpeg = await bgraToJpegInBackground(pixels, iw, ih);
        img.dispose();
        out.add(DraftPage(original: jpeg, width: iw, height: ih, filter: ScanFilter.original));
      }
      return out;
    } finally {
      await doc.dispose();
    }
  }

  /// Returns null if the user picked nothing.
  static Future<ImportResult?> fromGallery({void Function()? onPicked}) async {
    final files = await ImagePicker().pickMultiImage();
    if (files.isEmpty) return null;
    onPicked?.call();
    final drafts = <DraftPage>[], failed = <String>[];
    for (final f in files) {
      try {
        drafts.add(await fromImageBytes(await f.readAsBytes()));
      } catch (_) {
        failed.add(f.name);
      }
    }
    return ImportResult(drafts, failed);
  }

  /// Lets the user pick image files and PDFs from the system file browser.
  /// Returns null if they cancelled.
  static Future<ImportResult?> fromFiles({void Function()? onPicked}) async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', ...imageExtensions],
    );
    if (files.isEmpty) return null;
    onPicked?.call();
    final drafts = <DraftPage>[], failed = <String>[];
    for (final f in files) {
      try {
        // Android may return a content:// URI with no file path, so read
        // through the picker's own accessor rather than opening a path.
        final bytes = await f.readAsBytes();
        if (f.extension?.toLowerCase() == 'pdf') {
          drafts.addAll(await fromPdf(bytes, name: f.name));
        } else {
          drafts.add(await fromImageBytes(bytes));
        }
      } catch (_) {
        failed.add(f.name);
      }
    }
    return ImportResult(drafts, failed);
  }
}
