import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import '../app_state.dart';
import '../data/exporter.dart';
import '../data/importer.dart';
import '../pdf/pdf_tools.dart';
import 'library_actions.dart';
import 'convert_actions.dart';
import 'deliver.dart';
import 'pdf_options_sheet.dart';

/// Tools that work on PDF files from the phone's storage (not on the
/// app's documents). Results are shared or saved as new files; the
/// originals are never changed.
class PdfToolboxScreen extends ConsumerStatefulWidget {
  const PdfToolboxScreen({super.key});

  @override
  ConsumerState<PdfToolboxScreen> createState() => _PdfToolboxScreenState();
}

class _PdfToolboxScreenState extends ConsumerState<PdfToolboxScreen> {
  bool _busy = false;
  String? _status;

  /// Password each picked file was opened with (encrypted files only), so
  /// results can say they lost it, and compression can keep it.
  final _passwords = <String, String>{};

  Future<void> _run(String label, Future<void> Function() task) async {
    setState(() {
      _busy = true;
      _status = label;
    });
    try {
      await task();
    } on PdfPasswordException {
      if (mounted) toast(context, '密码不对');
    } on FormatException catch (e) {
      if (mounted) toast(context, e.message);
    } catch (e) {
      if (mounted) toast(context, '失败：$e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = null;
        });
      }
    }
  }

  void _progress(String s) {
    if (mounted) setState(() => _status = s);
  }

  // ---------------------------------------------------------------- input

  Future<List<PlatformFile>> _pickPdfs({bool multiple = false}) async {
    if (multiple) return FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
    final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['pdf']);
    return f == null ? const [] : [f];
  }

  /// Opens from the file's path when it has one (no copy of a big file in
  /// memory); content:// picks without a path are read into memory.
  static Future<PdfDocument> _openRaw(PlatformFile f, {String? password}) async {
    final path = f.path;
    if (path != null && await File(path).exists()) return PdfTools.open(path, password: password);
    return PdfTools.openData(await f.readAsBytes(), f.name, password: password);
  }

  /// Opens a picked PDF, asking for the password when it is encrypted.
  Future<PdfDocument?> _open(PlatformFile f) async {
    try {
      return await _openRaw(f);
    } on PdfPasswordException {
      String? error;
      for (var attempt = 0; attempt < 3; attempt++) {
        if (!mounted) return null;
        final pw = await askPassword(context, title: '“${f.name}”需要密码', error: error);
        if (pw == null) return null;
        try {
          final d = await _openRaw(f, password: pw);
          _passwords[f.name] = pw;
          return d;
        } on PdfPasswordException {
          error = '密码不对';
        }
      }
      return null;
    }
  }

  /// Tells the user when a result no longer has the source's password.
  void _warnUnprotected(Iterable<PlatformFile> sources) {
    if (mounted && sources.any((f) => _passwords.containsKey(f.name))) {
      toast(context, '注意：原文件有密码，生成的文件没有密码');
    }
  }

  // --------------------------------------------------------------- output

  static String _base(String name) => p.basenameWithoutExtension(name);

  Future<void> _deliver(List<(String, Uint8List)> outputs, {String mime = mimePdf}) =>
      deliverFiles(context, outputs, mime: mime);

  static String _size(int b) => fileSizeLabel(b);

  Future<int?> _askNumber(String title, {String initial = ''}) async {
    final v = await promptText(context, title: title, initial: initial, maxLength: 4);
    final n = int.tryParse(v ?? '');
    if (v != null && (n == null || n < 1) && mounted) toast(context, '请输入正整数');
    return n != null && n >= 1 ? n : null;
  }

  // ---------------------------------------------------------------- tools

  Future<void> _merge() async {
    final files = await _pickPdfs(multiple: true);
    if (files.isEmpty || !mounted) return;
    final ordered = await Navigator.of(context).push<List<PlatformFile>>(
      MaterialPageRoute(builder: (_) => _OrderFilesScreen(files: files)),
    );
    if (ordered == null) return;
    if (ordered.length < 2) {
      if (mounted) toast(context, '至少要两个文件才能合并');
      return;
    }
    await _run('正在合并…', () async {
      final docs = <PdfDocument>[];
      try {
        for (final f in ordered) {
          final d = await _open(f);
          if (d == null) return;
          docs.add(d);
        }
        final out = await PdfTools.merge(docs);
        _warnUnprotected(ordered);
        await _deliver([('${_base(ordered.first.name)}_合并.pdf', out)]);
      } finally {
        for (final d in docs) {
          await d.dispose();
        }
      }
    });
  }

  Future<void> _split() async {
    final f = (await _pickPdfs()).firstOrNull;
    if (f == null || !mounted) return;
    await _run('正在拆分…', () async {
      final d = await _open(f);
      if (d == null) return;
      try {
        if (!mounted) return;
        final n = d.pages.length;
        final mode = await showModalBottomSheet<String>(
          context: context,
          builder: (ctx) => SafeArea(
            child: Wrap(children: [
              ListTile(title: Text('“${f.name}”共 $n 页，怎么拆？')),
              ListTile(leading: const Icon(Icons.filter_1), title: const Text('每页一个文件'), onTap: () => Navigator.pop(ctx, 'one')),
              ListTile(leading: const Icon(Icons.view_module_outlined), title: const Text('每 N 页一个文件'), onTap: () => Navigator.pop(ctx, 'every')),
              ListTile(
                leading: const Icon(Icons.edit_note),
                title: const Text('按范围拆'),
                subtitle: const Text('例如 1-3；4-6；7-'),
                onTap: () => Navigator.pop(ctx, 'ranges'),
              ),
            ]),
          ),
        );
        if (mode == null || !mounted) return;
        List<List<int>> groups;
        switch (mode) {
          case 'one':
            groups = splitEvery(n, 1);
          case 'every':
            final k = await _askNumber('每份几页', initial: '2');
            if (k == null) return;
            groups = splitEvery(n, k);
          default:
            final spec = await promptText(context, title: '每份的页码，用分号隔开', hint: '1-3；4-6；7-', maxLength: 300);
            if (spec == null) return;
            groups = [
              for (final part in spec.replaceAll('；', ';').split(';'))
                if (part.trim().isNotEmpty) parsePageRanges(part, n),
            ];
        }
        if (groups.isEmpty) throw const FormatException('没有写任何页码');
        _progress('正在生成 ${groups.length} 个文件…');
        final outs = await PdfTools.split(d, groups);
        _warnUnprotected([f]);
        await _deliver([
          for (var i = 0; i < outs.length; i++) ('${_base(f.name)}_${i + 1}.pdf', outs[i]),
        ]);
      } finally {
        await d.dispose();
      }
    });
  }

  Future<void> _extract() async {
    final f = (await _pickPdfs()).firstOrNull;
    if (f == null || !mounted) return;
    await _run('正在提取…', () async {
      final d = await _open(f);
      if (d == null) return;
      try {
        if (!mounted) return;
        final spec = await promptText(context, title: '要哪些页（共 ${d.pages.length} 页）', hint: '例如 1-3,5,8-', maxLength: 300);
        if (spec == null) return;
        final pages = parsePageRanges(spec, d.pages.length);
        final out = await PdfTools.assemble([for (final n in pages) (doc: d, page: n, quarterTurns: 0)]);
        _warnUnprotected([f]);
        await _deliver([('${_base(f.name)}_摘录.pdf', out)]);
      } finally {
        await d.dispose();
      }
    });
  }

  Future<void> _organize() async {
    final f = (await _pickPdfs()).firstOrNull;
    if (f == null || !mounted) return;
    PdfDocument? d;
    await _run('正在打开…', () async => d = await _open(f));
    final doc = d;
    if (doc == null) return;
    try {
      if (!mounted) return;
      final picks = await Navigator.of(context).push<List<(int, int)>>(
        MaterialPageRoute(builder: (_) => _OrganizeScreen(doc: doc, name: f.name)),
      );
      if (picks == null || !mounted) return;
      await _run('正在保存…', () async {
        final out = await PdfTools.assemble([for (final (n, t) in picks) (doc: doc, page: n, quarterTurns: t)]);
        _warnUnprotected([f]);
        await _deliver([('${_base(f.name)}_整理.pdf', out)]);
      });
    } finally {
      // The organizer's thumbnails may still be painting during its pop
      // animation; let it finish before the document goes away.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await doc.dispose();
    }
  }

  Future<void> _decrypt() async {
    final f = (await _pickPdfs()).firstOrNull;
    if (f == null || !mounted) return;
    await _run('正在解密…', () async {
      PdfDocument? d;
      try {
        // Not encrypted: nothing to do.
        d = await _openRaw(f);
        if (mounted) toast(context, '这个 PDF 没有设置打开密码');
        return;
      } on PdfPasswordException {
        // expected
      } finally {
        await d?.dispose();
      }
      d = await _open(f);
      if (d == null) return;
      try {
        final out = await PdfTools.decrypt(d);
        await _deliver([('${_base(f.name)}_无密码.pdf', out)]);
      } finally {
        await d.dispose();
      }
    });
  }

  Future<void> _toImages() async {
    final f = (await _pickPdfs()).firstOrNull;
    if (f == null || !mounted) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(children: [
          const ListTile(title: Text('PDF 转图片')),
          ListTile(leading: const Icon(Icons.image_outlined), title: const Text('导出 JPG（200 dpi）'), onTap: () => Navigator.pop(ctx, 'jpg')),
          ListTile(
            leading: const Icon(Icons.library_add_outlined),
            title: const Text('导入到文档库'),
            subtitle: const Text('每页成为一张扫描页，可以继续编辑、识别'),
            onTap: () => Navigator.pop(ctx, 'import'),
          ),
        ]),
      ),
    );
    if (choice == null || !mounted) return;
    await _run('正在转换…', () async {
      if (choice == 'import') {
        // Ask for the password first if needed; the importer renders on its own.
        final probe = await _open(f);
        if (probe == null) return;
        await probe.dispose();
        final drafts = await Importer.fromPdf(await f.readAsBytes(), name: f.name, password: _passwords[f.name]);
        if (drafts.isEmpty) throw const FormatException('没有页面');
        final id = await ref.read(storeProvider).createDocument(_base(f.name), drafts);
        if (mounted) context.push('/doc/$id');
        return;
      }
      final d = await _open(f);
      if (d == null) return;
      try {
        final outs = <(String, Uint8List)>[];
        for (var i = 1; i <= d.pages.length; i++) {
          _progress('正在转换第 $i / ${d.pages.length} 页…');
          final jpg = (await PdfTools.toImages(d, dpi: 200, pages: [i])).single;
          outs.add(('${_base(f.name)}_$i.jpg', jpg));
        }
        _warnUnprotected([f]);
        await _deliver(outs, mime: 'image/jpeg');
      } finally {
        await d.dispose();
      }
    });
  }

  Future<void> _compress() async {
    final f = (await _pickPdfs()).firstOrNull;
    if (f == null || !mounted) return;
    final level = await showModalBottomSheet<(int, int)>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(children: [
          const ListTile(
            title: Text('压缩 PDF'),
            subtitle: Text('每页重新存成图片：适合扫描件；文字版 PDF 的文字会变成图片，不能再选中搜索。'),
          ),
          ListTile(title: const Text('轻度（150 dpi）'), onTap: () => Navigator.pop(ctx, (150, 80))),
          ListTile(title: const Text('中等（110 dpi）'), onTap: () => Navigator.pop(ctx, (110, 65))),
          ListTile(title: const Text('最小（80 dpi）'), onTap: () => Navigator.pop(ctx, (80, 50))),
        ]),
      ),
    );
    if (level == null || !mounted) return;
    await _run('正在压缩…', () async {
      final before = await f.length() ?? 0;
      final d = await _open(f);
      if (d == null) return;
      try {
        // A protected source stays protected with the same password.
        final out = await PdfTools.compress(d, dpi: level.$1, quality: level.$2, password: _passwords[f.name]);
        if (mounted && before > 0) toast(context, '${_size(before)} → ${_size(out.length)}');
        await _deliver([('${_base(f.name)}_压缩.pdf', out)]);
      } finally {
        await d.dispose();
      }
    });
  }

  /// PDF -> Word / Excel. Has its own progress dialog, so not inside _run.
  Future<void> _convert(ConvertTarget target) async {
    final f = (await _pickPdfs()).firstOrNull;
    if (f == null || !mounted) return;
    PdfDocument? d;
    try {
      d = await _open(f);
    } catch (e) {
      if (mounted) toast(context, '打开失败：$e');
      return;
    }
    if (d == null) return;
    try {
      if (!mounted) return;
      await convertPdf(context, ref, d, _base(f.name), target);
    } finally {
      await d.dispose();
    }
  }

  Future<void> _imagesToPdf() async {
    final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: Importer.imageExtensions);
    if (files.isEmpty || !mounted) return;
    final ordered = files.length < 2
        ? files
        : await Navigator.of(context).push<List<PlatformFile>>(MaterialPageRoute(builder: (_) => _OrderFilesScreen(files: files)));
    if (ordered == null || ordered.isEmpty || !mounted) return;
    final opts = await askPdfOptions(context, const PdfOptions(size: PdfPageSize.a4), showSearchable: false, action: '生成 PDF');
    if (opts == null || !mounted) return;
    await _run('正在生成…', () async {
      final images = [for (final f in ordered) await f.readAsBytes()];
      final out = await PdfTools.imagesToPdf(images, opts);
      await _deliver([('${_base(ordered.first.name)}.pdf', out)]);
    });
  }

  @override
  Widget build(BuildContext context) {
    Widget tool(IconData icon, String title, String sub, Future<void> Function() onTap) => ListTile(
          leading: Icon(icon),
          title: Text(title),
          subtitle: Text(sub),
          enabled: !_busy,
          onTap: onTap,
        );
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('PDF 工具箱'),
          bottom: _busy ? const PreferredSize(preferredSize: Size.fromHeight(4), child: LinearProgressIndicator()) : null,
        ),
        body: ListView(children: [
          if (_status != null) Padding(padding: const EdgeInsets.all(12), child: Text(_status!, textAlign: TextAlign.center)),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('处理手机里的 PDF 文件，结果另存为新文件，原文件不变。', style: TextStyle(fontSize: 12)),
          ),
          tool(Icons.merge_type, '合并 PDF', '把几个 PDF 按顺序合成一个', _merge),
          tool(Icons.call_split, '拆分 PDF', '每页一份、每 N 页一份，或按页码范围', _split),
          tool(Icons.content_cut, '提取页面', '挑出某些页另存', _extract),
          tool(Icons.view_carousel_outlined, '整理页面', '删除、旋转、调整页面顺序', _organize),
          tool(Icons.compress, '压缩 PDF', '重新存成较小的图片，适合扫描件', _compress),
          tool(Icons.lock_open, '去掉密码', '知道密码时，另存一份不用密码的', _decrypt),
          tool(Icons.image_outlined, 'PDF 转图片', '每页导出为 JPG，或导入到文档库', _toImages),
          tool(Icons.picture_as_pdf_outlined, '图片转 PDF', '可选纸张、压缩和打开密码', _imagesToPdf),
          tool(Icons.description_outlined, 'PDF 转 Word', '还原标题、段落、表格和图片；文字版 PDF 直接取文字', () => _convert(ConvertTarget.word)),
          tool(Icons.table_chart_outlined, 'PDF 转 Excel', '把页面里的表格转成工作表，保留合并单元格', () => _convert(ConvertTarget.excel)),
        ]),
      ),
    );
  }
}

/// Put picked files in order before merging.
class _OrderFilesScreen extends StatefulWidget {
  const _OrderFilesScreen({required this.files});
  final List<PlatformFile> files;

  @override
  State<_OrderFilesScreen> createState() => _OrderFilesScreenState();
}

class _OrderFilesScreenState extends State<_OrderFilesScreen> {
  late final _files = [...widget.files];

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('调整顺序'),
          actions: [
            TextButton(
              onPressed: _files.isEmpty ? null : () => Navigator.pop(context, _files),
              child: const Text('完成'),
            ),
          ],
        ),
        body: ReorderableListView.builder(
          itemCount: _files.length,
          onReorderItem: (from, to) => setState(() => _files.insert(to, _files.removeAt(from))),
          itemBuilder: (_, i) => ListTile(
            key: ValueKey('${_files[i].name}#${identityHashCode(_files[i])}'),
            leading: CircleAvatar(child: Text('${i + 1}')),
            title: Text(_files[i].name),
            trailing: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => setState(() => _files.removeAt(i)),
            ),
          ),
        ),
      );
}

/// Page organizer for one PDF: delete, rotate, reorder. Pops the result
/// as (page number, extra quarter turns) in the new order.
class _OrganizeScreen extends StatefulWidget {
  const _OrganizeScreen({required this.doc, required this.name});
  final PdfDocument doc;
  final String name;

  @override
  State<_OrganizeScreen> createState() => _OrganizeScreenState();
}

class _OrganizeScreenState extends State<_OrganizeScreen> {
  late final _pages = [for (var i = 1; i <= widget.doc.pages.length; i++) (i, 0)];

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text('整理 · ${_pages.length} 页'),
          actions: [
            TextButton(
              onPressed: _pages.isEmpty ? null : () => Navigator.pop(context, _pages),
              child: const Text('保存'),
            ),
          ],
        ),
        body: ReorderableListView.builder(
          padding: const EdgeInsets.all(8),
          itemCount: _pages.length,
          buildDefaultDragHandles: false,
          onReorderItem: (from, to) => setState(() => _pages.insert(to, _pages.removeAt(from))),
          itemBuilder: (_, i) {
            final (n, turns) = _pages[i];
            final page = widget.doc.pages[n - 1];
            return Card(
              key: ValueKey(n),
              child: Row(children: [
                SizedBox(
                  width: 100,
                  height: 120,
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: RotatedBox(
                      quarterTurns: turns,
                      child: PdfPageView(document: widget.doc, pageNumber: n, maximumDpi: 72),
                    ),
                  ),
                ),
                Expanded(
                  child: Text('原第 $n 页${turns == 0 ? '' : ' · 转 ${turns * 90}°'}\n${page.width.round()} × ${page.height.round()} pt'),
                ),
                IconButton(
                  tooltip: '旋转',
                  icon: const Icon(Icons.rotate_right),
                  onPressed: () => setState(() => _pages[i] = (n, (turns + 1) % 4)),
                ),
                IconButton(
                  tooltip: '删除',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: _pages.length <= 1 ? null : () => setState(() => _pages.removeAt(i)),
                ),
                ReorderableDragStartListener(index: i, child: const Padding(padding: EdgeInsets.all(12), child: Icon(Icons.drag_handle))),
              ]),
            );
          },
        ),
      );
}
