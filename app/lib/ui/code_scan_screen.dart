import 'package:flutter/material.dart';
import 'package:flutter_zxing/flutter_zxing.dart';
import 'package:permission_handler/permission_handler.dart';

import '../scan/codes.dart';
import 'code_sheet.dart';
import 'permissions.dart';

/// Live QR code / barcode scanner (zxing-cpp on the camera stream), with
/// a button to read a picture from the gallery instead.
class CodeScanScreen extends StatefulWidget {
  const CodeScanScreen({super.key});

  @override
  State<CodeScanScreen> createState() => _CodeScanScreenState();
}

class _CodeScanScreenState extends State<CodeScanScreen> {
  bool? _allowed;
  bool _showing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final ok = await ensurePermission(context, Permission.camera, '相机');
      if (mounted) setState(() => _allowed = ok);
    });
  }

  Future<void> _found(List<Code> codes) async {
    if (_showing || !mounted) return;
    final found = [
      for (final c in codes)
        if (c.isValid && c.text != null) FoundCode(c.text!, (c.format ?? 0).name),
    ];
    if (found.isEmpty) return;
    _showing = true;
    await showCodes(context, found);
    _showing = false;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white, title: const Text('扫码')),
        body: switch (_allowed) {
          null => const Center(child: CircularProgressIndicator()),
          false => const Center(child: Text('没有相机权限', style: TextStyle(color: Colors.white))),
          true => ReaderWidget(
              onScan: (c) => _found([c]),
              onMultiScan: (cs) => _found(cs.codes),
              tryHarder: true,
              tryInverted: true,
              showToggleCamera: false,
              cropPercent: 0.7,
              scanDelaySuccess: const Duration(milliseconds: 1500),
            ),
        },
      );
}
