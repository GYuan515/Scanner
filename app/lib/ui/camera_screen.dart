import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

import '../data/page_store.dart';
import '../scan/quad.dart';
import '../scan/stability.dart';
import 'permissions.dart';
import 'quad_overlay.dart';
import 'review_screen.dart';
import '../scan/background.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key, this.appendTo, this.insertAt, this.folderId, this.retake = false});

  /// When set, captured pages are added to this document.
  final int? appendTo;

  /// With [appendTo]: index to insert the new pages at; null appends.
  final int? insertAt;

  /// Folder a new document is created in (null = top level).
  final int? folderId;

  /// Retake mode: shoots one photo and pops it as a [DraftPage] instead
  /// of opening the review screen.
  final bool retake;

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  CameraController? _ctrl;
  String? _error;
  bool _busy = false;
  bool _detecting = false;
  late bool _batch = !widget.retake;
  bool _auto = true;
  final _stability = StabilityTracker();
  FlashMode _flash = FlashMode.off;
  final _drafts = <DraftPage>[];

  /// Latest live outline, already mapped to upright preview coordinates.
  Quad? _liveQuad;
  Size? _liveSize;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ctrl?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _ctrl;
    if (c == null || !c.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      _ctrl = null;
      c.dispose();
      if (mounted) setState(() {});
    } else if (state == AppLifecycleState.resumed) {
      _init();
    }
  }

  Future<void> _init() async {
    if (!await ensurePermission(context, Permission.camera, '相机')) {
      if (mounted) setState(() => _error = '没有相机权限');
      return;
    }
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) {
        setState(() => _error = '没有可用的摄像头');
        return;
      }
      final back = cams.firstWhere((c) => c.lensDirection == CameraLensDirection.back, orElse: () => cams.first);
      final ctrl = CameraController(
        back,
        ResolutionPreset.veryHigh,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await ctrl.initialize();
      await ctrl.setFlashMode(_flash);
      if (!mounted) {
        await ctrl.dispose();
        return;
      }
      setState(() {
        _ctrl = ctrl;
        _error = null;
      });
      await ctrl.startImageStream((img) => _onFrame(img, back.sensorOrientation));
    } on CameraException catch (e) {
      setState(() => _error = e.code == 'CameraAccessDenied' ? '没有相机权限，请在系统设置中允许' : '相机打开失败：${e.description ?? e.code}');
    }
  }

  void _onFrame(CameraImage img, int sensorOrientation) {
    if (_detecting || _busy) return;
    _detecting = true;
    final plane = img.planes.first;
    final bytes = Uint8List.fromList(plane.bytes);
    final w = img.width, h = img.height, stride = plane.bytesPerRow;
    detectLumaInBackground(bytes, w, h, stride).then((q) {
      if (!mounted) return;
      // Frames arrive in sensor orientation (landscape); the preview is
      // shown upright in portrait. Rotate the outline to match.
      final rotate = w > h ? sensorOrientation : 0;
      final quad = q == null ? null : _rotateQuad(q, w.toDouble(), h.toDouble(), rotate);
      final size = rotate % 180 == 0 ? Size(w.toDouble(), h.toDouble()) : Size(h.toDouble(), w.toDouble());
      setState(() {
        _liveQuad = quad;
        _liveSize = size;
      });
      if (_auto && !_busy && _stability.update(quad, size)) _capture();
    }).catchError((_) {
      // Detection is best-effort; a bad frame just shows no outline.
    }).whenComplete(() {
      // Throttle to roughly 6 fps so capture stays responsive.
      Future.delayed(const Duration(milliseconds: 160), () => _detecting = false);
    });
  }

  static Quad _rotateQuad(Quad q, double w, double h, int degrees) {
    Offset r(Offset p) => switch (degrees) {
          90 => Offset(h - p.dy, p.dx),
          180 => Offset(w - p.dx, h - p.dy),
          270 => Offset(p.dy, w - p.dx),
          _ => p,
        };
    return Quad.ordered(q.points.map(r).toList());
  }

  Future<void> _capture() async {
    final c = _ctrl;
    if (c == null || _busy) return;
    setState(() => _busy = true);
    try {
      await c.stopImageStream();
      final file = await c.takePicture();
      final raw = await file.readAsBytes();
      final prepared = await prepareInBackground(raw);
      final draft = DraftPage.fromPrepared(prepared);
      if (widget.retake) {
        if (mounted) Navigator.of(context).pop(draft);
        return;
      }
      _drafts.add(draft);
      if (!_batch) {
        await _review();
        return;
      }
      if (mounted && c.value.isInitialized) {
        await c.startImageStream((img) => _onFrame(img, c.description.sensorOrientation));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('拍摄失败：$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _review() async {
    if (_drafts.isEmpty) return;
    final c = _ctrl;
    if (c != null && c.value.isStreamingImages) await c.stopImageStream();
    if (!mounted) return;
    final docId = await Navigator.of(context).push<int>(MaterialPageRoute(
      // Shared list: deletions in review are reflected here.
      builder: (_) => ReviewScreen(drafts: _drafts, appendTo: widget.appendTo, insertAt: widget.insertAt, folderId: widget.folderId),
    ));
    if (!mounted) return;
    if (docId != null) {
      // This screen was opened through go_router, so leave it the same way.
      if (widget.appendTo == null) {
        context.pushReplacement('/doc/$docId');
      } else {
        context.pop();
      }
      return;
    }
    // Came back to keep shooting; the review screen may have deleted some.
    setState(() {});
    if (c != null && c.value.isInitialized && !c.value.isStreamingImages) {
      await c.startImageStream((img) => _onFrame(img, c.description.sensorOrientation));
    }
  }

  Future<void> _toggleFlash() async {
    final next = _flash == FlashMode.off ? FlashMode.torch : FlashMode.off;
    await _ctrl?.setFlashMode(next);
    setState(() => _flash = next);
  }

  @override
  Widget build(BuildContext context) {
    final c = _ctrl;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.retake ? '重拍' : '拍摄'),
        actions: [
          TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: _auto ? Colors.amberAccent : Colors.white70),
            onPressed: () => setState(() {
              _auto = !_auto;
              _stability.reset();
            }),
            icon: Icon(_auto ? Icons.motion_photos_auto : Icons.motion_photos_off_outlined),
            label: Text(_auto ? '自动' : '手动'),
          ),
          IconButton(
            tooltip: '手电筒',
            icon: Icon(_flash == FlashMode.off ? Icons.flash_off : Icons.flash_on),
            onPressed: c == null ? null : _toggleFlash,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: Center(child: _preview(c))),
          _controls(),
        ],
      ),
    );
  }

  Widget _preview(CameraController? c) {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(_error!, style: const TextStyle(color: Colors.white), textAlign: TextAlign.center),
          const SizedBox(height: 16),
          OutlinedButton(
            style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
            onPressed: () {
              setState(() => _error = null);
              _init();
            },
            child: const Text('重试'),
          ),
        ]),
      );
    }
    if (c == null || !c.value.isInitialized) return const CircularProgressIndicator();
    // previewSize is reported in landscape; the portrait preview uses its
    // inverse aspect ratio.
    final ps = c.value.previewSize!;
    final aspect = ps.height / ps.width;
    return AspectRatio(
      aspectRatio: aspect,
      child: Stack(fit: StackFit.expand, children: [
        CameraPreview(c),
        if (_liveSize != null)
          CustomPaint(
            painter: QuadPainter(
              quad: _liveQuad,
              imageSize: _liveSize!,
              // Turns green as the page holds still before auto-capture.
              color: _auto && _stability.progress > 0.5 ? Colors.greenAccent : const Color(0xFF1A73E8),
            ),
          ),
        if (_busy) const ColoredBox(color: Color(0x66000000), child: Center(child: CircularProgressIndicator())),
      ]),
    );
  }

  Widget _controls() {
    final last = _drafts.isEmpty ? null : _drafts.last;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (!widget.retake) SegmentedButton<bool>(
            style: SegmentedButton.styleFrom(foregroundColor: Colors.white, selectedForegroundColor: Colors.black),
            segments: const [
              ButtonSegment(value: false, label: Text('单张')),
              ButtonSegment(value: true, label: Text('多张')),
            ],
            selected: {_batch},
            onSelectionChanged: _drafts.isEmpty ? (s) => setState(() => _batch = s.first) : null,
          ),
          const SizedBox(height: 16),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            SizedBox(
              width: 56,
              height: 56,
              child: last == null
                  ? null
                  : Badge(
                      label: Text('${_drafts.length}'),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Image.memory(last.original, fit: BoxFit.cover, cacheWidth: 120),
                      ),
                    ),
            ),
            GestureDetector(
              onTap: _busy ? null : _capture,
              child: Container(
                width: 74,
                height: 74,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 4),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(5),
                  child: DecoratedBox(
                    decoration: BoxDecoration(shape: BoxShape.circle, color: _busy ? Colors.grey : Colors.white),
                  ),
                ),
              ),
            ),
            SizedBox(
              width: 56,
              child: _batch && _drafts.isNotEmpty
                  ? IconButton.filled(tooltip: '完成', onPressed: _busy ? null : _review, icon: const Icon(Icons.check))
                  : null,
            ),
          ]),
        ]),
      ),
    );
  }
}
