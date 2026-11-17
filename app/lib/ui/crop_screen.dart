import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../scan/quad.dart';
import 'magnifier.dart';
import 'quad_overlay.dart';

/// Lets the user drag the four corners of the page outline.
/// Pops with the new [Quad], or null if cancelled.
class CropScreen extends StatefulWidget {
  const CropScreen({
    super.key,
    required this.image,
    required this.width,
    required this.height,
    this.initial,
    this.detected,
  });

  final Uint8List image;
  final int width;
  final int height;
  final Quad? initial;

  /// Auto-detected outline, offered as a reset option.
  final Quad? detected;

  @override
  State<CropScreen> createState() => _CropScreenState();
}

class _CropScreenState extends State<CropScreen> {
  late Quad _quad;
  int? _dragging;

  /// Decoded once for the magnifier; null until it is ready, and the editor
  /// stays usable (just without the loupe) if decoding fails.
  ui.Image? _decoded;

  Size get _imgSize => Size(widget.width.toDouble(), widget.height.toDouble());
  Quad get _full => Quad.fullImage(_imgSize.width, _imgSize.height);

  @override
  void initState() {
    super.initState();
    _quad = widget.initial ?? widget.detected ?? _full;
    _decode();
  }

  @override
  void dispose() {
    _decoded?.dispose();
    super.dispose();
  }

  Future<void> _decode() async {
    try {
      final img = await decodeImageFromList(widget.image);
      if (!mounted) {
        img.dispose();
        return;
      }
      setState(() => _decoded = img);
    } catch (_) {
      // No magnifier; dragging still works.
    }
  }

  int? _hit(Offset viewPos, ImageMapping m) {
    var best = -1;
    var bestD = 44.0; // touch slop in logical pixels
    for (var i = 0; i < 4; i++) {
      final d = (m.toView(_quad.points[i]) - viewPos).distance;
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    return best < 0 ? null : best;
  }

  @override
  Widget build(BuildContext context) {
    final valid = _quad.isConvex && _quad.area > 100;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('调整边框'),
        actions: [
          TextButton(
            onPressed: valid ? () => Navigator.pop(context, _quad) : null,
            child: const Text('确定'),
          ),
        ],
      ),
      body: Column(children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: LayoutBuilder(builder: (context, box) {
              final view = Size(box.maxWidth, box.maxHeight);
              final m = ImageMapping(_imgSize, view);
              final img = _decoded;
              final dragging = _dragging;
              return GestureDetector(
                onPanStart: (d) {
                  final i = _hit(d.localPosition, m);
                  // setState so the magnifier shows up on touch-down.
                  if (i != _dragging) setState(() => _dragging = i);
                },
                onPanUpdate: (d) {
                  final i = _dragging;
                  if (i == null) return;
                  final p = m.toImage(d.localPosition);
                  setState(() => _quad = _quad.replace(i, p).clamp(_imgSize.width, _imgSize.height));
                },
                onPanEnd: (_) => setState(() => _dragging = null),
                onPanCancel: () => setState(() => _dragging = null),
                child: Stack(fit: StackFit.expand, children: [
                  Image.memory(widget.image, fit: BoxFit.contain, gaplessPlayback: true),
                  CustomPaint(
                    painter: QuadPainter(
                      quad: _quad,
                      imageSize: _imgSize,
                      handles: true,
                      color: valid ? const Color(0xFF1A73E8) : Colors.red,
                    ),
                  ),
                  if (img != null && dragging != null)
                    CustomPaint(
                      painter: LoupePainter(
                        image: img,
                        imageSize: _imgSize,
                        quad: _quad,
                        corner: _quad.points[dragging],
                        color: valid ? const Color(0xFF1A73E8) : Colors.red,
                      ),
                    ),
                ]),
              );
            }),
          ),
        ),
        SafeArea(
          top: false,
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            _action(Icons.crop_free, '全图', () => setState(() => _quad = _full)),
            if (widget.detected != null)
              _action(Icons.auto_fix_high, '自动', () => setState(() => _quad = widget.detected!)),
          ]),
        ),
      ]),
    );
  }

  Widget _action(IconData icon, String label, VoidCallback onTap) => TextButton.icon(
        style: TextButton.styleFrom(foregroundColor: Colors.white),
        onPressed: onTap,
        icon: Icon(icon),
        label: Text(label),
      );
}
