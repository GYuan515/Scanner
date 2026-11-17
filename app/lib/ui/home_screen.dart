import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app_state.dart';
import '../data/db.dart';
import '../data/importer.dart';
import 'doc_operations.dart';
import 'library_actions.dart';
import 'library_widgets.dart';
import 'review_screen.dart';

/// Browses one folder (null = top level): subfolders, documents, tag
/// filter, view mode and sort, and a multi-select mode for batch actions.
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key, this.folderId});
  final int? folderId;

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  /// Selected document ids; non-empty means selection mode.
  final _selected = <int>{};

  /// When set, shows every document with this tag instead of the folder.
  int? _tagId;

  bool get _selecting => _selected.isNotEmpty;

  DocQuery _query(LibraryPrefs prefs) => (folderId: widget.folderId, tagId: _tagId, sort: prefs.sort);

  Future<void> _import({required bool files}) async {
    final messenger = ScaffoldMessenger.of(context);
    void busy() => messenger.showSnackBar(const SnackBar(content: Text('正在处理…'), duration: Duration(minutes: 5)));
    ImportResult? result;
    try {
      result = files ? await Importer.fromFiles(onPicked: busy) : await Importer.fromGallery(onPicked: busy);
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text('导入失败：$e')));
      return;
    }
    messenger.hideCurrentSnackBar();
    if (result == null) return;
    if (result.failed.isNotEmpty) {
      messenger.showSnackBar(SnackBar(content: Text('${result.failed.length} 个文件无法读取，已跳过：${result.failed.join('、')}')));
    }
    if (result.drafts.isEmpty || !mounted) return;
    final docId = await Navigator.of(context).push<int>(
      MaterialPageRoute(builder: (_) => ReviewScreen(drafts: result!.drafts, folderId: widget.folderId)),
    );
    if (docId != null && mounted) context.push('/doc/$docId');
  }

  Future<void> _newFolder() async {
    final name = await promptText(context, title: '新建文件夹', hint: '文件夹名');
    if (name == null) return;
    await ref.read(dbProvider).createFolder(name, parentId: widget.folderId);
  }

  Future<void> _folderMenu(Folder f) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(children: [
          ListTile(title: Text(f.name, style: Theme.of(ctx).textTheme.titleMedium)),
          ListTile(leading: const Icon(Icons.edit_outlined), title: const Text('重命名'), onTap: () => Navigator.pop(ctx, 'rename')),
          ListTile(leading: const Icon(Icons.delete_outline), title: const Text('删除文件夹'), onTap: () => Navigator.pop(ctx, 'delete')),
        ]),
      ),
    );
    if (!mounted) return;
    final db = ref.read(dbProvider);
    switch (action) {
      case 'rename':
        final name = await promptText(context, title: '重命名文件夹', initial: f.name);
        if (name != null) await db.renameFolder(f.id, name);
      case 'delete':
        final ok = await confirm(
          context,
          title: '删除「${f.name}」？',
          message: '文件夹和其中的子文件夹会被删除，里面的文档放进回收站，30 天内可以恢复（恢复后在顶层）。',
          ok: '删除',
        );
        if (ok) await db.deleteFolder(f.id);
    }
  }

  Future<void> _tagMenu(Tag t) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(children: [
          ListTile(title: Text('#${t.name}', style: Theme.of(ctx).textTheme.titleMedium)),
          ListTile(leading: const Icon(Icons.edit_outlined), title: const Text('重命名标签'), onTap: () => Navigator.pop(ctx, 'rename')),
          ListTile(leading: const Icon(Icons.delete_outline), title: const Text('删除标签'), onTap: () => Navigator.pop(ctx, 'delete')),
        ]),
      ),
    );
    if (!mounted) return;
    final db = ref.read(dbProvider);
    switch (action) {
      case 'rename':
        final name = await promptText(context, title: '重命名标签', initial: t.name, maxLength: 40);
        if (name != null) {
          try {
            await db.renameTag(t.id, name);
          } catch (_) {
            if (mounted) toast(context, '已经有叫「$name」的标签');
          }
        }
      case 'delete':
        if (await confirm(context, title: '删除标签「${t.name}」？', message: '只删除标签，文档不受影响。', ok: '删除')) {
          await db.deleteTag(t.id);
          if (_tagId == t.id) setState(() => _tagId = null);
        }
    }
  }

  void _toggle(int id) => setState(() => _selected.contains(id) ? _selected.remove(id) : _selected.add(id));

  Future<void> _batch(String action, List<Document> visible) async {
    final ids = _selected.toList();
    final docs = visible.where((d) => _selected.contains(d.id)).toList();
    switch (action) {
      case 'all':
        setState(() => _selected.addAll(visible.map((d) => d.id)));
        return;
      case 'move':
        await moveDocs(context, ref, ids);
      case 'copy':
        await copyDocs(context, ref, ids);
      case 'merge':
        await mergeDocs(context, ref, ids);
      case 'tag':
        await editTags(context, ref, ids);
      case 'lock':
        await toggleLock(context, ref, docs);
      case 'delete':
        if (!await trashDocs(context, ref, ids)) return;
    }
    if (mounted) setState(_selected.clear);
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(libraryPrefsProvider);
    final docs = ref.watch(documentsProvider(_query(prefs)));
    final visible = docs.value ?? const <Document>[];
    // Drop selections that disappeared (moved, deleted elsewhere).
    if (docs.hasValue) _selected.retainAll(visible.map((d) => d.id));

    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(_selected.clear);
      },
      child: Scaffold(
        appBar: _selecting ? _selectionBar(visible) : _normalBar(prefs),
        body: docs.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('读取失败：$e')),
          data: (list) => _body(list, prefs),
        ),
        floatingActionButton: _selecting
            ? null
            : FloatingActionButton.extended(
                onPressed: () => context.push(widget.folderId == null ? '/scan' : '/scan?folder=${widget.folderId}'),
                icon: const Icon(Icons.document_scanner_outlined),
                label: const Text('扫描'),
              ),
      ),
    );
  }

  PreferredSizeWidget _normalBar(LibraryPrefs prefs) {
    final folder = widget.folderId == null ? null : ref.watch(folderProvider(widget.folderId!)).value;
    final notifier = ref.read(libraryPrefsProvider.notifier);
    return AppBar(
      title: Text(widget.folderId == null ? '我的文档' : (folder?.name ?? '')),
      actions: [
        IconButton(tooltip: '搜索', icon: const Icon(Icons.search), onPressed: () => context.push('/search')),
        PopupMenuButton<Object>(
          tooltip: '显示方式',
          icon: const Icon(Icons.sort),
          onSelected: (v) {
            if (v is ViewMode) notifier.setView(v);
            if (v is DocSort) notifier.setSort(v);
          },
          itemBuilder: (_) => [
            for (final v in ViewMode.values) CheckedPopupMenuItem(value: v, checked: prefs.view == v, child: Text(v.label)),
            const PopupMenuDivider(),
            for (final s in DocSort.values) CheckedPopupMenuItem(value: s, checked: prefs.sort == s, child: Text('按${s.label}')),
          ],
        ),
        PopupMenuButton<String>(
          onSelected: (k) async {
            switch (k) {
              case 'folder':
                await _newFolder();
              case 'gallery':
                await _import(files: false);
              case 'files':
                await _import(files: true);
              case 'recent':
                context.push('/recent');
              case 'trash':
                context.push('/trash');
              case 'codes':
                context.push('/codes');
              case 'pdftools':
                context.push('/pdf-tools');
              case 'settings':
                context.push('/settings');
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'folder', child: ListTile(leading: Icon(Icons.create_new_folder_outlined), title: Text('新建文件夹'))),
            PopupMenuItem(value: 'gallery', child: ListTile(leading: Icon(Icons.photo_library_outlined), title: Text('从相册导入'))),
            PopupMenuItem(value: 'files', child: ListTile(leading: Icon(Icons.file_open_outlined), title: Text('导入文件（图片、PDF）'))),
            PopupMenuDivider(),
            PopupMenuItem(value: 'recent', child: ListTile(leading: Icon(Icons.history), title: Text('最近打开'))),
            PopupMenuItem(value: 'trash', child: ListTile(leading: Icon(Icons.delete_outline), title: Text('回收站'))),
            PopupMenuItem(value: 'codes', child: ListTile(leading: Icon(Icons.qr_code_scanner), title: Text('扫码'))),
            PopupMenuItem(value: 'pdftools', child: ListTile(leading: Icon(Icons.handyman_outlined), title: Text('PDF 工具箱'))),
            PopupMenuItem(value: 'settings', child: ListTile(leading: Icon(Icons.settings_outlined), title: Text('设置'))),
          ],
        ),
      ],
    );
  }

  PreferredSizeWidget _selectionBar(List<Document> visible) {
    final docs = visible.where((d) => _selected.contains(d.id));
    final allLocked = docs.isNotEmpty && docs.every((d) => d.locked);
    return AppBar(
      leading: IconButton(icon: const Icon(Icons.close), onPressed: () => setState(_selected.clear)),
      title: Text('已选 ${_selected.length} 个'),
      actions: [
        IconButton(tooltip: '移动', icon: const Icon(Icons.drive_file_move_outline), onPressed: () => _batch('move', visible)),
        IconButton(tooltip: '删除', icon: const Icon(Icons.delete_outline), onPressed: () => _batch('delete', visible)),
        PopupMenuButton<String>(
          onSelected: (k) => _batch(k, visible),
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'all', child: Text('全选')),
            const PopupMenuItem(value: 'copy', child: Text('复制')),
            if (_selected.length >= 2) const PopupMenuItem(value: 'merge', child: Text('合并为一个文档')),
            const PopupMenuItem(value: 'tag', child: Text('添加标签')),
            PopupMenuItem(value: 'lock', child: Text(allLocked ? '取消加锁' : '加锁')),
          ],
        ),
      ],
    );
  }

  Widget _body(List<Document> docs, LibraryPrefs prefs) {
    final folders = _tagId == null ? ref.watch(foldersProvider(widget.folderId)).value ?? const <Folder>[] : const <Folder>[];
    final counts = ref.watch(folderCountsProvider).value ?? const <int?, int>{};
    final tags = ref.watch(tagsProvider).value ?? const <Tag>[];
    final empty = docs.isEmpty && folders.isEmpty;
    return CustomScrollView(slivers: [
      if (tags.isNotEmpty && !_selecting)
        SliverToBoxAdapter(
          child: SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(label: const Text('全部'), selected: _tagId == null, onSelected: (_) => setState(() => _tagId = null)),
                ),
                for (final t in tags)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: GestureDetector(
                      onLongPress: () => _tagMenu(t),
                      child: ChoiceChip(
                        label: Text('#${t.name}'),
                        selected: _tagId == t.id,
                        onSelected: (on) => setState(() => _tagId = on ? t.id : null),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      if (folders.isNotEmpty && !_selecting)
        SliverList.builder(
          itemCount: folders.length,
          itemBuilder: (_, i) {
            final f = folders[i];
            return ListTile(
              leading: const Icon(Icons.folder_outlined, size: 32),
              title: Text(f.name),
              subtitle: Text('${counts[f.id] ?? 0} 个文档'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/folder/${f.id}'),
              onLongPress: () => _folderMenu(f),
            );
          },
        ),
      if (folders.isNotEmpty && docs.isNotEmpty && !_selecting) const SliverToBoxAdapter(child: Divider(height: 1)),
      if (empty)
        SliverFillRemaining(hasScrollBody: false, child: _Empty(tagFilter: _tagId != null, inFolder: widget.folderId != null))
      else
        docSliver(
          docs: docs,
          mode: prefs.view,
          item: (d) => DocItem(
            doc: d,
            mode: prefs.view,
            selected: _selecting ? _selected.contains(d.id) : null,
            onTap: _selecting ? () => _toggle(d.id) : () => context.push('/doc/${d.id}'),
            onLongPress: () => _toggle(d.id),
          ),
        ),
      const SliverToBoxAdapter(child: SizedBox(height: 96)),
    ]);
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.tagFilter, required this.inFolder});
  final bool tagFilter;
  final bool inFolder;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final (title, hint) = tagFilter
        ? ('没有带这个标签的文档', '在文档里点"标签"给它加上')
        : inFolder
            ? ('文件夹是空的', '点右下角"扫描"，或在其他地方选中文档后"移动"到这里')
            : ('还没有文档', '点右下角"扫描"开始，或从右上角菜单导入');
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.description_outlined, size: 64, color: c.outline),
          const SizedBox(height: 12),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(hint, style: TextStyle(color: c.onSurfaceVariant), textAlign: TextAlign.center),
        ]),
      ),
    );
  }
}
