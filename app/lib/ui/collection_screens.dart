import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app_state.dart';
import '../data/db.dart';
import '../data/page_store.dart';
import 'library_actions.dart';
import 'library_widgets.dart';

class RecentScreen extends ConsumerWidget {
  const RecentScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final docs = ref.watch(recentProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('最近打开')),
      body: docs.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('读取失败：$e')),
        data: (list) => list.isEmpty
            ? const Center(child: Text('还没有打开过文档'))
            : CustomScrollView(slivers: [
                docSliver(
                  docs: list,
                  mode: ViewMode.list,
                  item: (d) => DocItem(
                    doc: d,
                    mode: ViewMode.list,
                    trailingText: d.lastOpenedAt == null ? null : '打开于 ${formatTime(d.lastOpenedAt!)}',
                    onTap: () => context.push('/doc/${d.id}'),
                  ),
                ),
              ]),
      ),
    );
  }
}

class TrashScreen extends ConsumerWidget {
  const TrashScreen({super.key});

  static int daysLeft(DateTime deletedAt, DateTime now) {
    final left = deletedAt.add(PageStore.trashRetention).difference(now).inHours / 24;
    return left.ceil().clamp(0, PageStore.trashRetention.inDays);
  }

  Future<void> _actions(BuildContext context, WidgetRef ref, Document d) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(children: [
          ListTile(title: Text(d.title, style: Theme.of(ctx).textTheme.titleMedium)),
          ListTile(leading: const Icon(Icons.restore), title: const Text('恢复'), onTap: () => Navigator.pop(ctx, 'restore')),
          ListTile(
            leading: const Icon(Icons.delete_forever_outlined),
            title: const Text('永久删除'),
            onTap: () => Navigator.pop(ctx, 'purge'),
          ),
        ]),
      ),
    );
    if (!context.mounted) return;
    switch (action) {
      case 'restore':
        await ref.read(dbProvider).restoreDocuments([d.id]);
        if (context.mounted) toast(context, '已恢复');
      case 'purge':
        if (await confirm(context, title: '永久删除「${d.title}」？', message: '删除后无法恢复。', ok: '永久删除')) {
          await ref.read(storeProvider).purgeDocument(d.id);
        }
    }
  }

  Future<void> _emptyAll(BuildContext context, WidgetRef ref, List<Document> docs) async {
    if (!await confirm(context, title: '清空回收站？', message: '${docs.length} 个文档会被永久删除，无法恢复。', ok: '清空')) return;
    final store = ref.read(storeProvider);
    for (final d in docs) {
      await store.purgeDocument(d.id);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final docs = ref.watch(trashProvider);
    final list = docs.value ?? const <Document>[];
    final now = DateTime.now();
    return Scaffold(
      appBar: AppBar(
        title: const Text('回收站'),
        actions: [
          if (list.isNotEmpty) TextButton(onPressed: () => _emptyAll(context, ref, list), child: const Text('清空')),
        ],
      ),
      body: docs.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('读取失败：$e')),
        data: (list) => list.isEmpty
            ? const Center(child: Text('回收站是空的'))
            : CustomScrollView(slivers: [
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text('删除的文档保留 30 天，到期自动清除。点文档可以恢复。'),
                  ),
                ),
                docSliver(
                  docs: list,
                  mode: ViewMode.list,
                  item: (d) => DocItem(
                    doc: d,
                    mode: ViewMode.list,
                    trailingText: '剩 ${daysLeft(d.deletedAt!, now)} 天',
                    onTap: () => _actions(context, ref, d),
                  ),
                ),
              ]),
      ),
    );
  }
}

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _ctrl = TextEditingController();
  Timer? _debounce;
  List<Document>? _results;
  int _generation = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () => _run(q));
  }

  Future<void> _run(String q) async {
    final gen = ++_generation;
    final res = await ref.read(dbProvider).search(q);
    // Ignore results of an older query that finished late.
    if (mounted && gen == _generation) setState(() => _results = q.trim().isEmpty ? null : res);
  }

  @override
  Widget build(BuildContext context) {
    final results = _results;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _ctrl,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(hintText: '搜索标题或文字内容', border: InputBorder.none),
          onChanged: _onChanged,
          onSubmitted: _run,
        ),
        actions: [
          if (_ctrl.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear),
              onPressed: () {
                _ctrl.clear();
                _onChanged('');
              },
            ),
        ],
      ),
      body: results == null
          ? const Center(child: Text('文字内容要先做过文字识别才能搜到'))
          : results.isEmpty
              ? const Center(child: Text('没有找到'))
              : CustomScrollView(slivers: [
                  docSliver(
                    docs: results,
                    mode: ViewMode.list,
                    item: (d) => DocItem(doc: d, mode: ViewMode.list, onTap: () => context.push('/doc/${d.id}')),
                  ),
                ]),
    );
  }
}
