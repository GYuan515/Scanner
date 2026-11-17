import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doc_scanner/data/exporter.dart';

/// Loads every bundled asset the app reads at runtime through rootBundle,
/// i.e. the way the app does on the phone. Other tests read these files
/// straight from disk, which passes even when pubspec.yaml forgets to
/// declare them (that is how the fonts went missing from the APK).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('PDF fonts are bundled', () async {
    final fonts = await PdfFonts.load();
    expect(fonts.latin.length, greaterThan(100000));
    expect(fonts.cjk.length, greaterThan(1000000));
  });

  test('OCR models and dictionary are bundled', () async {
    for (final name in [
      'ocr_det.onnx',
      'ocr_cls.onnx',
      'ocr_rec.onnx',
      'ocr_keys.txt',
      'selftest.onnx',
      'layout.onnx',
      'table.onnx',
      'layout_labels.txt',
      'table_tokens.txt',
    ]) {
      final data = await rootBundle.load('assets/models/$name');
      expect(data.lengthInBytes, greaterThan(50), reason: name);
    }
  });
}
