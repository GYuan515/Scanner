import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_zxing/flutter_zxing.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';

import '../app_state.dart';
import '../convert/layout.dart';
import '../error_log.dart';
import '../data/exporter.dart';
import '../pdf/pdf_tools.dart';
import '../scan/codes.dart';
import '../scan/image_ops.dart';

/// One check of a native dependency, run on the device.
class _Check {
  _Check(this.name, this.run);
  final String name;
  final Future<String> Function() run;
  String? result;
  bool? ok;
}

/// Runs each native library once (OpenCV, ONNX Runtime, PDFium) so a build
/// can be verified on a real phone without a full scan.
class DiagnosticsScreen extends ConsumerStatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  ConsumerState<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends ConsumerState<DiagnosticsScreen> {
  late final List<_Check> _checks = [
    _Check('OpenCV', _opencv),
    _Check('ONNX Runtime', _onnx),
    _Check('PDFium', _pdfium),
    _Check('文字识别', _ocr),
    _Check('二维码', _qr),
    _Check('PDF 工具', _pdfTools),
    _Check('版面分析', _layout),
  ];
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _runAll();
  }

  Future<void> _runAll() async {
    setState(() {
      _running = true;
      for (final c in _checks) {
        c.ok = null;
        c.result = null;
      }
    });
    for (final c in _checks) {
      final sw = Stopwatch()..start();
      try {
        final msg = await c.run();
        c.ok = true;
        c.result = '$msg（${sw.elapsedMilliseconds} ms）';
      } catch (e) {
        c.ok = false;
        c.result = '$e';
      }
      if (mounted) setState(() {});
    }
    if (mounted) setState(() => _running = false);
  }

  static Future<String> _opencv() => Isolate.run(() {
        final m = cv.Mat.zeros(240, 320, cv.MatType.CV_8UC3);
        cv.rectangle(m, cv.Rect(40, 40, 200, 120), cv.Scalar(255, 255, 255), thickness: -1);
        final gray = cv.cvtColor(m, cv.COLOR_BGR2GRAY);
        final mean = cv.mean(gray).val1;
        final (ok, jpg) = cv.imencode('.jpg', m);
        m.dispose();
        gray.dispose();
        if (!ok || jpg.isEmpty) throw StateError('imencode 失败');
        return '版本 ${cv.openCvVersion()}，灰度均值 ${mean.toStringAsFixed(1)}';
      });

  /// Runs a tiny bundled model (y = x + x) and checks the numbers.
  static Future<String> _onnx() async {
    final session = await OnnxRuntime().createSessionFromAsset('assets/models/selftest.onnx');
    try {
      final input = await OrtValue.fromList(Float32List.fromList([1, 2, 3, 4]), [4]);
      final out = await session.run({session.inputNames.first: input});
      final y = (await out.values.first.asFlattenedList()).map((v) => (v as num).toDouble()).toList();
      await input.dispose();
      for (final v in out.values) {
        await v.dispose();
      }
      const expected = [2.0, 4.0, 6.0, 8.0];
      for (var i = 0; i < 4; i++) {
        if ((y[i] - expected[i]).abs() > 1e-5) throw StateError('结果不对：$y');
      }
      final providers = await OnnxRuntime().getAvailableProviders();
      return '推理结果正确，可用后端：${providers.map((p) => p.name).join(', ')}';
    } finally {
      await session.close();
    }
  }

  /// Draws a line of text, saves it as PNG and reads it back through the
  /// OCR worker isolate: covers model extraction, the background-isolate
  /// plugin channel and the whole pipeline.
  Future<String> _ocr() async {
    const sample = '扫描测试 Scan 2026';
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(const Rect.fromLTWH(0, 0, 900, 220), Paint()..color = Colors.white);
    final tp = TextPainter(
      text: const TextSpan(text: sample, style: TextStyle(color: Colors.black, fontSize: 72)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, const Offset(40, 60));
    final image = await recorder.endRecording().toImage(900, 220);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final f = File(p.join((await getTemporaryDirectory()).path, 'ocr_selftest.png'));
    await f.writeAsBytes(png!.buffer.asUint8List(), flush: true);
    final engine = await ref.read(ocrEngineProvider.future);
    final result = await engine.recognizeFile(f.path);
    final got = result.text.replaceAll(RegExp(r'\s'), '');
    if (!got.contains('扫描测试') || !got.toLowerCase().contains('scan2026')) throw StateError('识别结果不对：${result.text}');
    return '识别出“${result.text}”';
  }

  /// Draws a page with a title, text and a ruled 4x3 table, then runs the
  /// layout and table-structure models on it in the worker.
  Future<String> _layout() async {
    const w = 1240.0, h = 1754.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..drawRect(const Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.white);
    void text(String s, double x, double y, double size) {
      final tp = TextPainter(
        text: TextSpan(text: s, style: TextStyle(color: Colors.black, fontSize: size)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x, y));
      tp.dispose();
    }

    text('季度经费报告', 420, 120, 64);
    for (var i = 0; i < 4; i++) {
      text('这是正文第 ${i + 1} 行，用来检查版面分析能不能分出段落和表格。', 110, 280 + i * 50.0, 30);
    }
    final line = Paint()
      ..color = Colors.black
      ..strokeWidth = 3;
    const x0 = 110.0, y0 = 600.0, cw = 340.0, rh = 70.0;
    for (var r = 0; r <= 4; r++) {
      canvas.drawLine(Offset(x0, y0 + r * rh), Offset(x0 + 3 * cw, y0 + r * rh), line);
    }
    for (var c = 0; c <= 3; c++) {
      canvas.drawLine(Offset(x0 + c * cw, y0), Offset(x0 + c * cw, y0 + 4 * rh), line);
    }
    const cells = [['季度', '预算', '支出'], ['一', '120', '115'], ['二', '150', '162'], ['三', '130', '128']];
    for (var r = 0; r < 4; r++) {
      for (var c = 0; c < 3; c++) {
        text(cells[r][c], x0 + c * cw + 30, y0 + r * rh + 18, 30);
      }
    }
    final image = await recorder.endRecording().toImage(w.toInt(), h.toInt());
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final f = File(p.join((await getTemporaryDirectory()).path, 'layout_selftest.png'));
    await f.writeAsBytes(png!.buffer.asUint8List(), flush: true);
    final engine = await ref.read(layoutEngineProvider.future);
    final regions = await engine.layout(f.path);
    final table = regions.where((r) => r.kind == RegionKind.table).toList();
    if (table.isEmpty) throw StateError('没找到表格：${regions.map((r) => r.kind.name).join(', ')}');
    final grid = await engine.table(f.path, table.first.box);
    if (grid.rows < 3 || grid.cols < 2) throw StateError('表格结构不对：${grid.rows} 行 ${grid.cols} 列');
    return '找到 ${regions.length} 个区域，表格 ${grid.rows} 行 ${grid.cols} 列';
  }

  /// Generates a QR code and reads it back with zxing-cpp.
  static Future<String> _qr() => Isolate.run(() {
        const text = 'https://example.com/scanner-selftest';
        final enc = zx.encodeBarcode(contents: text, params: EncodeParams(width: 300, height: 300, margin: 20));
        if (!enc.isValid || enc.data == null) throw StateError('生成失败：${enc.error}');
        final codes = readCodesLuma(enc.data!, enc.width ?? 300, enc.height ?? 300);
        if (codes.length != 1 || codes.single.text != text) throw StateError('读回的结果不对：${codes.map((c) => c.text)}');
        return '生成并读回 ${codes.single.format}';
      });

  /// Merges two PDFs (one page rotated), then writes an AES-256 encrypted
  /// PDF and opens it with and without the password.
  static Future<String> _pdfTools() async {
    Future<PdfDocument> make(String t) async {
      final d = pw.Document()..addPage(pw.Page(build: (_) => pw.Text(t)));
      return PdfTools.openData(await d.save(), '$t.pdf');
    }

    final a = await make('A'), b = await make('B');
    try {
      final merged = await PdfTools.assemble([
        (doc: a, page: 1, quarterTurns: 0),
        (doc: b, page: 1, quarterTurns: 1),
      ]);
      final m = await PdfTools.openData(merged, 'm.pdf');
      final int pages;
      final PdfPageRotation rotated;
      try {
        pages = m.pages.length;
        rotated = m.pages[1].rotation;
      } finally {
        await m.dispose();
      }
      if (pages != 2 || rotated != PdfPageRotation.clockwise90) throw StateError('合并结果不对：$pages 页，$rotated');
    } finally {
      await a.dispose();
      await b.dispose();
    }
    final locked = await PdfTools.imagesToPdf(
      [ImageOps.encodeJpeg(cv.Mat.zeros(40, 30, cv.MatType.CV_8UC3))],
      const PdfOptions(password: 'selftest'),
    );
    try {
      await (await PdfTools.openData(locked, 'l.pdf', password: 'wrong')).dispose();
      throw StateError('错误密码也能打开');
    } on PdfPasswordException {
      // expected
    }
    final ok = await PdfTools.openData(locked, 'l.pdf', password: 'selftest');
    await ok.dispose();
    return '合并、旋转、AES-256 加密都正常';
  }

  /// Builds a one-page PDF and renders it back.
  static Future<String> _pdfium() async {
    final doc = pw.Document()..addPage(pw.Page(build: (_) => pw.Center(child: pw.Text('pdfium'))));
    final bytes = await doc.save();
    final pdf = await PdfDocument.openData(bytes, sourceName: 'selftest.pdf');
    try {
      final page = pdf.pages.first;
      final img = await page.render(fullWidth: 200, fullHeight: 283, backgroundColor: 0xffffffff);
      if (img == null) throw StateError('渲染失败');
      final size = '${img.width}x${img.height}';
      img.dispose();
      return '打开并渲染 ${pdf.pages.length} 页，$size';
    } finally {
      await pdf.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('组件自检'),
        actions: [IconButton(tooltip: '重新检测', onPressed: _running ? null : _runAll, icon: const Icon(Icons.refresh))],
      ),
      body: ListView(children: [
        for (final c in _checks)
          ListTile(
            leading: switch (c.ok) {
              null => const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
              true => const Icon(Icons.check_circle, color: Colors.green),
              false => const Icon(Icons.error, color: Colors.red),
            },
            title: Text(c.name),
            subtitle: c.result == null ? null : SelectableText(c.result!),
          ),
        const Divider(),
        ListTile(
          title: const Text('错误日志'),
          trailing: TextButton(
            onPressed: () => setState(() => ErrorLog.instance?.clear()),
            child: const Text('清空'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          child: SelectableText(
            (ErrorLog.instance?.read() ?? '').isEmpty ? '没有记录' : ErrorLog.instance!.read(),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          ),
        ),
      ]),
    );
  }
}
