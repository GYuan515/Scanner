import 'package:flutter/material.dart';

import '../data/exporter.dart';

/// Asks for PDF export options: paper, margins, text layer, image quality
/// and an optional open password. Null if cancelled.
Future<PdfOptions?> askPdfOptions(
  BuildContext context,
  PdfOptions initial, {
  bool showSearchable = true,
  String action = '导出',
}) =>
    showModalBottomSheet<PdfOptions>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _PdfOptionsSheet(initial: initial, showSearchable: showSearchable, action: action),
    );

/// A widget (not a StatefulBuilder) so it owns and disposes the password
/// controller after the sheet has fully closed.
class _PdfOptionsSheet extends StatefulWidget {
  const _PdfOptionsSheet({required this.initial, required this.showSearchable, required this.action});
  final PdfOptions initial;
  final bool showSearchable;
  final String action;

  @override
  State<_PdfOptionsSheet> createState() => _PdfOptionsSheetState();
}

class _PdfOptionsSheetState extends State<_PdfOptionsSheet> {
  late var _size = widget.initial.size;
  late var _margin = widget.initial.margin;
  late var _searchable = widget.initial.searchable;
  late var _quality = widget.initial.quality;
  final _password = TextEditingController();
  bool _protect = false;
  bool _show = false;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final ok = !_protect || _password.text.length >= 4;
    return Padding(
      // Keep the password field above the keyboard.
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('纸张大小', style: t.titleSmall),
            const SizedBox(height: 8),
            SegmentedButton<PdfPageSize>(
              segments: [for (final v in PdfPageSize.values) ButtonSegment(value: v, label: Text(v.label))],
              selected: {_size},
              onSelectionChanged: (v) => setState(() => _size = v.first),
            ),
            const SizedBox(height: 16),
            Text('页边距', style: t.titleSmall),
            const SizedBox(height: 8),
            SegmentedButton<PdfMargin>(
              segments: [for (final v in PdfMargin.values) ButtonSegment(value: v, label: Text(v.label))],
              selected: {_margin},
              onSelectionChanged: (v) => setState(() => _margin = v.first),
            ),
            const SizedBox(height: 16),
            Text('图片质量（越低文件越小）', style: t.titleSmall),
            const SizedBox(height: 8),
            SegmentedButton<PdfQuality>(
              segments: [for (final v in PdfQuality.values) ButtonSegment(value: v, label: Text(v.label))],
              selected: {_quality},
              onSelectionChanged: (v) => setState(() => _quality = v.first),
            ),
            if (widget.showSearchable)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('可搜索 PDF'),
                subtitle: const Text('加一层看不见的文字，可以搜索、选中和复制'),
                value: _searchable,
                onChanged: (v) => setState(() => _searchable = v),
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('设置打开密码'),
              subtitle: const Text('AES-256 加密，忘记密码就打不开了'),
              value: _protect,
              onChanged: (v) => setState(() => _protect = v),
            ),
            if (_protect)
              TextField(
                controller: _password,
                obscureText: !_show,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: '密码（至少 4 位）',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(_show ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _show = !_show),
                  ),
                ),
              ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: ok
                    ? () => Navigator.pop(
                          context,
                          PdfOptions(
                            size: _size,
                            margin: _margin,
                            searchable: _searchable,
                            quality: _quality,
                            password: _protect ? _password.text : null,
                          ),
                        )
                    : null,
                child: Text(widget.action),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
