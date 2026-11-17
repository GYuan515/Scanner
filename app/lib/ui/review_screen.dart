import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_state.dart';
import '../data/page_store.dart';
import '../scan/image_ops.dart';
import '../scan/quad.dart';
import 'crop_screen.dart';
import '../scan/background.dart';

/// Shows captured pages before saving: per-page filter, crop, rotate and
/// delete. Pops with the document id once saved, or null to keep
/// shooting. It never navigates elsewhere itself: the caller decides
/// what comes next, so no closing page's context is reused.
class ReviewScreen extends ConsumerStatefulWidget {
  const ReviewScreen({super.key, required this.drafts, this.appendTo, this.insertAt, this.folderId});

  /// Mutated in place so the camera screen sees deletions.
  final List<DraftPage> drafts;
  final int? appendTo;

  /// With [appendTo]: page index to insert at; null appends at the end.
  final int? insertAt;

  /// Folder a new document is created in (null = top level).
  final int? folderId;

  @override
  ConsumerState<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends ConsumerState<ReviewScreen> {
  final _pager = PageController();
  int _index = 0;
  bool _saving = false;

  /// Preview cache keyed by draft identity + settings.
  final _previews = <DraftPage, (String, Uint8List)>{};
  final _pending = <DraftPage>{};
  /// Last render failure per draft: (settings key it failed for, message).
  final _errors = <DraftPage, (String, String)>{};

  List<DraftPage> get _drafts => widget.drafts;

  String _key(DraftPage d) => '${d.quad?.toJson()}|${d.filter.name}|${d.rotation}';

  Uint8List? _preview(DraftPage d) {
    final cached = _previews[d];
    final key = _key(d);
    if (cached != null && cached.$1 == key) return cached.$2;
    // A failed render is not retried on every rebuild; the user taps 重试.
    final failed = _errors[d];
    if (failed != null && failed.$1 == key) return cached?.$2;
    if (!_pending.contains(d)) {
      _pending.add(d);
      _errors.remove(d);
      processInBackground(d.original, quad: d.quad, filter: d.filter, rotation: d.rotation, maxSide: 1600).then((bytes) {
        _pending.remove(d);
        if (!mounted) return;
        setState(() => _previews[d] = (key, bytes));
      }, onError: (Object e) {
        _pending.remove(d);
        if (!mounted) return;
        // Show the failure instead of spinning forever.
        setState(() => _errors[d] = (key, '$e'));
      });
    }
    // Show the stale preview while the new one renders.
    return cached?.$2;
  }

  Future<void> _crop() async {
    final d = _drafts[_index];
    final q = await Navigator.of(context).push<Quad>(MaterialPageRoute(
      builder: (_) => CropScreen(image: d.original, width: d.width, height: d.height, initial: d.quad, detected: d.detected),
    ));
    if (q != null) setState(() => d.quad = q);
  }

  void _delete() {
    setState(() {
      _previews.remove(_drafts.removeAt(_index));
      if (_index >= _drafts.length) _index = _drafts.length - 1;
    });
    if (_drafts.isEmpty) Navigator.of(context).pop();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final store = ref.read(storeProvider);
    try {
      final int docId;
      if (widget.appendTo != null) {
        docId = widget.appendTo!;
        await store.insertPages(docId, _drafts, at: widget.insertAt);
      } else {
        final now = DateTime.now();
        String two(int v) => v.toString().padLeft(2, '0');
        final title = '扫描 ${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}.${two(now.minute)}';
        docId = await store.createDocument(title, _drafts, folderId: widget.folderId);
      }
      if (!mounted) return;
      Navigator.of(context).pop(docId);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存失败：$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _drafts[_index];
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: AppBar(
          title: Text('${_index + 1} / ${_drafts.length}'),
          actions: [
            TextButton.icon(
              onPressed: _saving ? null : () => Navigator.of(context).pop(),
              icon: const Icon(Icons.add_a_photo_outlined),
              label: const Text('继续拍'),
            ),
          ],
        ),
        body: Column(children: [
          Expanded(
            child: PageView.builder(
              controller: _pager,
              itemCount: _drafts.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (_, i) {
                final dr = _drafts[i];
                final img = _preview(dr);
                final err = _errors[dr];
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: img == null && err != null
                      ? Center(
                          child: Column(mainAxisSize: MainAxisSize.min, children: [
                            const Icon(Icons.broken_image_outlined, size: 48),
                            const SizedBox(height: 8),
                            Text('处理失败：${err.$2}', textAlign: TextAlign.center),
                            const SizedBox(height: 8),
                            OutlinedButton(onPressed: () => setState(() => _errors.remove(dr)), child: const Text('重试')),
                          ]),
                        )
                      : img == null
                      ? const Center(child: CircularProgressIndicator())
                      : InteractiveViewer(child: Image.memory(img, fit: BoxFit.contain, gaplessPlayback: true)),
                );
              },
            ),
          ),
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final f in ScanFilter.values)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ChoiceChip(
                      label: Text(f.label),
                      selected: d.filter == f,
                      onSelected: (_) => setState(() => d.filter = f),
                    ),
                  ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                _tool(Icons.crop, '裁剪', _saving ? null : _crop),
                _tool(Icons.rotate_right, '旋转', _saving ? null : () => setState(() => d.rotation = (d.rotation + 1) % 4)),
                _tool(Icons.delete_outline, '删除', _saving ? null : _delete),
                FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.check),
                  label: const Text('保存'),
                ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _tool(IconData icon, String label, VoidCallback? onTap) => TextButton(
        onPressed: onTap,
        child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(icon), const SizedBox(height: 2), Text(label)]),
      );
}
