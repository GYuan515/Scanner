import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;

import 'layout.dart';
import 'table.dart';

/// Layout and table-structure models on ONNX Runtime, for the worker
/// isolate. Models come from tool/prepare_layout_models.py: uint8 NHWC BGR
/// input "image"; layout outputs score8..64 / box8..64, table loc / probs.
class OnnxLayoutBackend {
  OnnxLayoutBackend._(this._layout, this._table, this.labels, this.vocab);

  final OrtSession _layout;
  final OrtSession _table;
  final List<String> labels;
  final List<String> vocab;

  static Future<OnnxLayoutBackend> open({
    required String layout,
    required String table,
    required List<String> labels,
    required List<String> tableTokens,
  }) async {
    final ort = OnnxRuntime();
    final options = OrtSessionOptions(intraOpNumThreads: 4);
    final l = await ort.createSession(layout, options: options);
    try {
      final t = await ort.createSession(table, options: options);
      return OnnxLayoutBackend._(l, t, labels, TableDecoder.vocabulary(tableTokens));
    } catch (_) {
      await l.close();
      rethrow;
    }
  }

  Future<void> close() async {
    await _layout.close();
    await _table.close();
  }

  static Uint8List _packed(cv.Mat m) {
    final c = m.isContinuous ? m : m.clone();
    final b = Uint8List.fromList(c.data);
    if (!identical(c, m)) c.dispose();
    return b;
  }

  static Float32List _floats(List<dynamic> v) =>
      v is Float32List ? v : Float32List.fromList(v.cast<num>().map((x) => x.toDouble()).toList());

  Future<Map<String, Float32List>> _run(OrtSession s, Uint8List bgr, List<int> shape) async {
    final input = await OrtValue.fromList(bgr, shape);
    Map<String, OrtValue>? out;
    try {
      out = await s.run({'image': input});
      return {for (final e in out.entries) e.key: _floats(await e.value.asFlattenedList())};
    } finally {
      await input.dispose();
      for (final v in out?.values ?? const <OrtValue>[]) {
        await v.dispose();
      }
    }
  }

  /// Layout regions of a BGR page image, in its pixels.
  Future<List<LayoutRegion>> layout(cv.Mat page) async {
    // Same as the reference: a plain (aspect-ignoring) bilinear resize.
    final small = cv.resize(page, (LayoutDecoder.inputW, LayoutDecoder.inputH), interpolation: cv.INTER_LINEAR);
    final Map<String, Float32List> out;
    try {
      out = await _run(_layout, _packed(small), [1, LayoutDecoder.inputH, LayoutDecoder.inputW, 3]);
    } finally {
      small.dispose();
    }
    return LayoutDecoder.decode(
      [for (final s in LayoutDecoder.strides) out['score$s']!],
      [for (final s in LayoutDecoder.strides) out['box$s']!],
      labels.length,
      page.cols,
      page.rows,
    );
  }

  /// Table structure of [region] (page pixels); cell boxes in page pixels.
  Future<TableGrid> table(cv.Mat page, cv.Rect region) async {
    final crop = page.region(region);
    final owned = <cv.Mat>[crop];
    try {
      const n = TableDecoder.size;
      final ratio = n / math.max(crop.rows, crop.cols);
      final rw = (crop.cols * ratio).floor().clamp(1, n), rh = (crop.rows * ratio).floor().clamp(1, n);
      final small = cv.resize(crop, (rw, rh), interpolation: cv.INTER_LINEAR);
      owned.add(small);
      // Pad with the colour the in-graph normalisation maps to ~0 (what
      // the reference pads with after normalising).
      final pad = cv.Mat.fromScalar(n, n, cv.MatType.CV_8UC3, cv.Scalar(124, 116, 104, 0));
      owned.add(pad);
      final roi = pad.region(cv.Rect(0, 0, rw, rh));
      small.copyTo(roi);
      roi.dispose();
      final out = await _run(_table, _packed(pad), [1, n, n, 3]);
      final loc = out['loc']!, probs = out['probs']!;
      final steps = loc.length ~/ 8;
      final (structure, boxes) = TableDecoder.decode(loc, probs, steps, vocab, ratio);
      return TableDecoder.grid(structure, boxes, origin: Offset(region.x.toDouble(), region.y.toDouble()));
    } finally {
      for (final m in owned) {
        m.dispose();
      }
    }
  }
}
