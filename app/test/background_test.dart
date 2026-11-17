import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:doc_scanner/scan/background.dart';
import 'package:doc_scanner/scan/image_ops.dart';

Uint8List _jpeg(int w, int h) {
  final m = cv.Mat.fromScalar(h, w, cv.MatType.CV_8UC3, cv.Scalar.all(180));
  final (_, b) = cv.imencode('.jpg', m);
  m.dispose();
  return b;
}

/// Stands in for a widget State: it owns something that cannot cross
/// isolates, and a sibling closure in the same method uses `this`.
/// Calling Isolate.run with an inline closure here fails with
/// "object is unsendable"; the background helpers must not.
class _FakeState {
  final port = ReceivePort();
  bool mounted = true;
  Uint8List? result;

  Future<void> preview(Uint8List src) {
    final f = processInBackground(src, filter: ScanFilter.enhance, maxSide: 100);
    return f.then((b) {
      if (mounted) result = b;
    });
  }

  /// The old ReviewScreen pattern: the `.then` closure uses `this`, so
  /// the isolate closure in the same scope drags `this` along.
  Future<Object?> inlineIsolate(Uint8List src) {
    return Isolate.run(() => ImageOps.process(src, maxSide: 100)).then<Object?>((b) {
      if (mounted) result = b;
      return null;
    }, onError: (Object e) => e);
  }
}

void main() {
  test('inline Isolate.run inside such an object fails (documents the bug)', () async {
    final s = _FakeState();
    expect(await s.inlineIsolate(_jpeg(200, 100)), isNotNull);
    s.port.close();
  });

  test('background helpers work when called from an object holding unsendables', () async {
    final s = _FakeState();
    await s.preview(_jpeg(200, 100));
    final m = cv.imdecode(s.result!, cv.IMREAD_COLOR);
    expect((m.cols, m.rows), (100, 50));
    m.dispose();
    s.port.close();
  });

  test('every helper runs in an isolate', () async {
    final src = _jpeg(400, 300);
    final prepared = await prepareInBackground(src);
    expect((prepared.width, prepared.height), (400, 300));
    final (proc, thumb) = await renderPageInBackground(src, null, ScanFilter.grayscale, 1);
    expect(proc, isNotEmpty);
    expect(thumb, isNotEmpty);
    expect(await detectLumaInBackground(Uint8List(64 * 48), 64, 48, 64), isNull);
    expect(await bgraToJpegInBackground(Uint8List(8 * 6 * 4), 8, 6), isNotEmpty);
    expect(await stitchInBackground([src, src]), isNotEmpty);
  });
}
