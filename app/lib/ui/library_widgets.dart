import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_state.dart';
import '../data/db.dart';

String formatTime(DateTime t) {
  final d = t.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

/// First page thumbnail, or a lock symbol for locked documents so the
/// content is not visible in lists.
class DocCover extends ConsumerWidget {
  const DocCover({super.key, required this.doc, this.cacheWidth = 240});
  final Document doc;
  final int cacheWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = Theme.of(context).colorScheme;
    if (doc.locked) {
      return ColoredBox(
        color: c.surfaceContainerHighest,
        child: Center(child: Icon(Icons.lock_outline, color: c.onSurfaceVariant)),
      );
    }
    final pages = ref.watch(pagesProvider(doc.id)).value ?? const <ScanPage>[];
    if (pages.isEmpty) return ColoredBox(color: c.surfaceContainerHighest);
    final store = ref.read(storeProvider);
    return Image.file(
      File(store.file(pages.first.thumbFile).path),
      key: ValueKey(pages.first.thumbFile),
      fit: BoxFit.cover,
      cacheWidth: cacheWidth,
      errorBuilder: (_, _, _) => ColoredBox(color: c.surfaceContainerHighest),
    );
  }
}

class _Subtitle extends ConsumerWidget {
  const _Subtitle({required this.doc, this.trailing});
  final Document doc;
  final String? trailing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.watch(pagesProvider(doc.id)).value?.length;
    final tags = ref.watch(tagsOfProvider(doc.id)).value ?? const <Tag>[];
    final parts = [
      formatTime(doc.updatedAt),
      if (n != null) '$n 页',
      if (tags.isNotEmpty) tags.map((t) => '#${t.name}').join(' '),
      ?trailing,
    ];
    return Text(parts.join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis);
  }
}

/// One document in [mode]. [selected] is null outside selection mode.
class DocItem extends StatelessWidget {
  const DocItem({
    super.key,
    required this.doc,
    required this.mode,
    this.selected,
    this.onTap,
    this.onLongPress,
    this.trailingText,
  });

  final Document doc;
  final ViewMode mode;
  final bool? selected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final String? trailingText;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final check = selected == null
        ? null
        : Icon(selected! ? Icons.check_circle : Icons.radio_button_unchecked, color: selected! ? c.primary : c.outline);
    final title = Row(children: [
      if (doc.locked) Padding(padding: const EdgeInsets.only(right: 4), child: Icon(Icons.lock, size: 14, color: c.primary)),
      Expanded(child: Text(doc.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
    ]);
    switch (mode) {
      case ViewMode.list:
        return ListTile(
          selected: selected ?? false,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          leading: SizedBox(
            width: 48,
            height: 64,
            child: ClipRRect(borderRadius: BorderRadius.circular(4), child: DocCover(doc: doc, cacheWidth: 144)),
          ),
          title: title,
          subtitle: _Subtitle(doc: doc, trailing: trailingText),
          trailing: check,
          onTap: onTap,
          onLongPress: onLongPress,
        );
      case ViewMode.grid:
      case ViewMode.large:
        return Card(
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: (selected ?? false) ? BorderSide(color: c.primary, width: 2) : BorderSide.none,
          ),
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(
                child: Stack(fit: StackFit.expand, children: [
                  DocCover(doc: doc, cacheWidth: mode == ViewMode.large ? 600 : 300),
                  if (check != null)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: DecoratedBox(
                        decoration: BoxDecoration(color: c.surface, shape: BoxShape.circle),
                        child: check,
                      ),
                    ),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
                child: DefaultTextStyle.merge(style: Theme.of(context).textTheme.bodyMedium, child: title),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                child: DefaultTextStyle.merge(
                  style: Theme.of(context).textTheme.bodySmall,
                  child: _Subtitle(doc: doc, trailing: trailingText),
                ),
              ),
            ]),
          ),
        );
    }
  }
}

/// [docs] laid out as a sliver in [mode].
Widget docSliver({
  required List<Document> docs,
  required ViewMode mode,
  required Widget Function(Document doc) item,
}) {
  switch (mode) {
    case ViewMode.list:
      return SliverList.separated(
        itemCount: docs.length,
        separatorBuilder: (_, _) => const Divider(height: 1, indent: 80),
        itemBuilder: (_, i) => item(docs[i]),
      );
    case ViewMode.grid:
    case ViewMode.large:
      return SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        sliver: SliverGrid.builder(
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: mode == ViewMode.large ? 240 : 140,
            childAspectRatio: 0.62,
            mainAxisSpacing: 4,
            crossAxisSpacing: 4,
          ),
          itemCount: docs.length,
          itemBuilder: (_, i) => item(docs[i]),
        ),
      );
  }
}
