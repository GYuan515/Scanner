import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../convert/layout.dart';
import '../convert/layout_backend.dart';
import '../convert/table.dart';
import 'ocr_pipeline.dart';
import 'ocr_queue.dart';
import 'ocr_result.dart';
import 'onnx_backend.dart';

/// Layout analysis and table structure, for document conversion.
abstract class LayoutEngine {
  Future<List<LayoutRegion>> layout(String path);

  /// Table structure inside [region] (image pixels); cell boxes in image
  /// pixels, cell texts still empty.
  Future<TableGrid> table(String path, Rect region);
}

/// Text recognition (and layout / table models) on a long-lived worker
/// isolate.
///
/// The worker keeps the ONNX sessions loaded and does all OpenCV work, so
/// the UI isolate only sends a file path and receives JSON back. ONNX
/// Runtime is reached from the worker through the plugin's method channel,
/// which background isolates may use once they register the root
/// isolate's token. Messages: [id, command, ...args] -> [id, ok, json].
class OcrService implements OcrEngine, LayoutEngine {
  OcrService._(this._isolate, this._send, this._replies, this._exit);

  final Isolate _isolate;
  final SendPort _send;
  final ReceivePort _replies;
  final ReceivePort _exit;
  final _pending = <int, Completer<String>>{};
  var _nextId = 0;
  var _closed = false;

  /// True once the worker died or was shut down; callers should start a
  /// new service then (see liveOcrService in app_state.dart).
  bool get isClosed => _closed;

  static const _assets = [
    'ocr_det.onnx',
    'ocr_cls.onnx',
    'ocr_rec.onnx',
    'ocr_keys.txt',
    'layout.onnx',
    'table.onnx',
    'layout_labels.txt',
    'table_tokens.txt',
  ];

  /// Bump when any bundled model changes, so the copies get replaced.
  static const _modelsVersion = '2';

  static Future<OcrService> start() async {
    final dir = await _extractModels();
    final dict = await File(p.join(dir, 'ocr_keys.txt')).readAsString();
    final replies = ReceivePort();
    // Exit and uncaught-error notifications: a dead worker must fail the
    // pending requests instead of leaving callers waiting forever.
    final exit = ReceivePort();
    final ready = Completer<SendPort>();
    OcrService? service;
    replies.listen((msg) {
      if (!ready.isCompleted) {
        if (msg is SendPort) {
          ready.complete(msg);
        } else {
          ready.completeError(StateError('OCR 引擎启动失败：$msg'));
        }
        return;
      }
      service?._onReply(msg as List);
    });
    exit.listen((msg) {
      final why = msg is List ? '${msg.first}' : '已退出';
      if (!ready.isCompleted) ready.completeError(StateError('OCR 引擎启动失败：$why'));
      service?._fail(StateError('OCR 引擎$why'));
    });
    final isolate = await Isolate.spawn(
      _worker,
      _WorkerArgs(replies.sendPort, RootIsolateToken.instance!, dir, dict),
      debugName: 'ocr',
      onExit: exit.sendPort,
      onError: exit.sendPort,
    );
    try {
      final send = await ready.future.timeout(const Duration(seconds: 60));
      return service = OcrService._(isolate, send, replies, exit);
    } catch (_) {
      isolate.kill();
      replies.close();
      exit.close();
      rethrow;
    }
  }

  /// Copies the bundled models out of the APK; ONNX Runtime needs real
  /// files. A version stamp skips the (tens of MB) asset reads when the
  /// copies are current.
  static Future<String> _extractModels() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'ocr'));
    await dir.create(recursive: true);
    final stamp = File(p.join(dir.path, 'models.version'));
    final current = await stamp.exists() && (await stamp.readAsString()) == _modelsVersion;
    if (current && _assets.every((n) => File(p.join(dir.path, n)).existsSync())) return dir.path;
    for (final name in _assets) {
      final data = await rootBundle.load('assets/models/$name');
      final f = File(p.join(dir.path, name));
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
      await tmp.rename(f.path);
    }
    await stamp.writeAsString(_modelsVersion, flush: true);
    return dir.path;
  }

  Future<String> _call(String cmd, List<Object> args) {
    if (_closed) return Future.error(StateError('OCR 已关闭'));
    final id = _nextId++;
    final c = Completer<String>();
    _pending[id] = c;
    _send.send([id, cmd, ...args]);
    // A request that never returns (stuck native call) must not block the
    // caller forever; generous, since big pages take a while.
    return c.future.timeout(const Duration(minutes: 3), onTimeout: () {
      _pending.remove(id);
      throw OcrException('处理超时');
    });
  }

  /// Reads the text in the image at [path]. With [region] (image pixels)
  /// only that area is read.
  @override
  Future<OcrResult> recognizeFile(String path, {Rect? region}) async {
    final json = await _call('ocr', [
      path,
      if (region != null) ...[region.left, region.top, region.width, region.height],
    ]);
    return OcrResult.fromJsonString(json);
  }

  @override
  Future<List<LayoutRegion>> layout(String path) async {
    final json = await _call('layout', [path]);
    return [for (final r in jsonDecode(json) as List) LayoutRegion.fromJson(r as Map<String, dynamic>)];
  }

  @override
  Future<TableGrid> table(String path, Rect region) async {
    final json = await _call('table', [path, region.left, region.top, region.width, region.height]);
    return TableGrid.fromJson(jsonDecode(json) as Map<String, dynamic>);
  }

  void _onReply(List msg) {
    final c = _pending.remove(msg[0] as int);
    if (c == null) return;
    if (msg[1] == true) {
      c.complete(msg[2] as String);
    } else {
      c.completeError(OcrException(msg[2] as String));
    }
  }

  void _fail(Object error) {
    _closed = true;
    for (final c in _pending.values) {
      c.completeError(error);
    }
    _pending.clear();
  }

  void dispose() {
    if (_closed) return;
    // The worker closes its ONNX sessions (they live in the plugin, not in
    // the isolate) and exits; kill() is only the fallback.
    _send.send(const ['close']);
    _fail(StateError('OCR 已关闭'));
    Future<void>.delayed(const Duration(seconds: 5), () {
      _isolate.kill();
      _replies.close();
      _exit.close();
    });
  }
}

class OcrException implements Exception {
  OcrException(this.message);
  final String message;
  @override
  String toString() => message;
}

class _WorkerArgs {
  _WorkerArgs(this.reply, this.token, this.dir, this.dict);
  final SendPort reply;
  final RootIsolateToken token;
  final String dir;
  final String dict;
}

cv.Rect _rect(cv.Mat img, List m, int at) {
  final x = (m[at] as double).round().clamp(0, img.cols - 1);
  final y = (m[at + 1] as double).round().clamp(0, img.rows - 1);
  final w = (m[at + 2] as double).round().clamp(1, img.cols - x);
  final h = (m[at + 3] as double).round().clamp(1, img.rows - y);
  return cv.Rect(x, y, w, h);
}

Future<void> _worker(_WorkerArgs args) async {
  final OcrPipeline pipeline;
  final OnnxOcrBackend backend;
  try {
    BackgroundIsolateBinaryMessenger.ensureInitialized(args.token);
    backend = await OnnxOcrBackend.open(
      det: p.join(args.dir, 'ocr_det.onnx'),
      cls: p.join(args.dir, 'ocr_cls.onnx'),
      rec: p.join(args.dir, 'ocr_rec.onnx'),
    );
    pipeline = OcrPipeline(backend, OcrPipeline.keysFrom(args.dict));
  } catch (e) {
    args.reply.send('$e');
    return;
  }
  // Layout / table models load on first use: plain OCR does not need them.
  OnnxLayoutBackend? layout;
  Future<OnnxLayoutBackend> layoutBackend() async => layout ??= await OnnxLayoutBackend.open(
        layout: p.join(args.dir, 'layout.onnx'),
        table: p.join(args.dir, 'table.onnx'),
        labels: const LineSplitter().convert(await File(p.join(args.dir, 'layout_labels.txt')).readAsString()),
        tableTokens: const LineSplitter().convert(await File(p.join(args.dir, 'table_tokens.txt')).readAsString()),
      );

  final inbox = ReceivePort();
  args.reply.send(inbox.sendPort);
  // `await for` handles one request at a time, in arrival order.
  await for (final msg in inbox) {
    final m = msg as List;
    if (m.first == 'close') {
      await backend.close();
      await layout?.close();
      inbox.close();
      return;
    }
    final id = m[0] as int;
    final cmd = m[1] as String;
    try {
      final img = cv.imread(m[2] as String, flags: cv.IMREAD_COLOR);
      try {
        if (img.isEmpty) throw OcrException('无法读取图片');
        final String json;
        switch (cmd) {
          case 'ocr':
            final result = await pipeline.run(img, region: m.length == 7 ? _rect(img, m, 3) : null);
            json = result.toJsonString();
          case 'layout':
            final regions = await (await layoutBackend()).layout(img);
            json = jsonEncode([for (final r in regions) r.toJson()]);
          case 'table':
            final grid = await (await layoutBackend()).table(img, _rect(img, m, 3));
            json = jsonEncode(grid.toJson());
          default:
            throw OcrException('未知请求 $cmd');
        }
        args.reply.send([id, true, json]);
      } finally {
        img.dispose();
      }
    } catch (e) {
      args.reply.send([id, false, '$e']);
    }
  }
}
