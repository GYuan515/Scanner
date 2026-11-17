import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import 'ocr_pipeline.dart';

/// Runs the three bundled models through ONNX Runtime.
///
/// The models are the ones produced by `tool/prepare_ocr_models.py`: uint8
/// NHWC input named `image`; det returns `prob_u8`, cls `prob`, rec
/// `index` + `prob`.
class OnnxOcrBackend implements OcrBackend {
  OnnxOcrBackend._(this._det, this._cls, this._rec);

  final OrtSession _det;
  final OrtSession _cls;
  final OrtSession _rec;

  static Future<OnnxOcrBackend> open({required String det, required String cls, required String rec}) async {
    final ort = OnnxRuntime();
    final options = OrtSessionOptions(intraOpNumThreads: 4);
    final sessions = <OrtSession>[];
    try {
      for (final path in [det, cls, rec]) {
        sessions.add(await ort.createSession(path, options: options));
      }
    } catch (_) {
      for (final s in sessions) {
        await s.close();
      }
      rethrow;
    }
    return OnnxOcrBackend._(sessions[0], sessions[1], sessions[2]);
  }

  Future<void> close() async {
    await _det.close();
    await _cls.close();
    await _rec.close();
  }

  Future<Map<String, List<dynamic>>> _run(OrtSession s, Uint8List bgr, List<int> shape) async {
    final input = await OrtValue.fromList(bgr, shape);
    Map<String, OrtValue>? out;
    try {
      out = await s.run({'image': input});
      return {for (final e in out.entries) e.key: await e.value.asFlattenedList()};
    } finally {
      await input.dispose();
      for (final v in out?.values ?? const <OrtValue>[]) {
        await v.dispose();
      }
    }
  }

  @override
  Future<Uint8List> detect(Uint8List bgr, int height, int width) async {
    final out = await _run(_det, bgr, [1, height, width, 3]);
    final map = out['prob_u8']!;
    return map is Uint8List ? map : Uint8List.fromList(map.cast<int>());
  }

  @override
  Future<Float32List> orientation(Uint8List bgr, int n) async {
    final out = await _run(_cls, bgr, [n, OcrPipeline.clsHeight, OcrPipeline.clsWidth, 3]);
    return _floats(out['prob']!);
  }

  @override
  Future<RecOutput> recognize(Uint8List bgr, int n, int width) async {
    final out = await _run(_rec, bgr, [n, OcrPipeline.recHeight, width, 3]);
    final index = out['index']!;
    final prob = _floats(out['prob']!);
    return RecOutput(
      index is Int32List ? index : Int32List.fromList(index.cast<num>().map((v) => v.toInt()).toList()),
      prob,
      prob.length ~/ n,
    );
  }

  static Float32List _floats(List<dynamic> v) =>
      v is Float32List ? v : Float32List.fromList(v.cast<num>().map((x) => x.toDouble()).toList());
}
