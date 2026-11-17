import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app_state.dart';
import '../data/temp_files.dart';
import '../data/db.dart';
import 'library_actions.dart';

// Document operations shared by the library's selection mode and the
// document screen's menu. They show their own feedback.

Future<void> moveDocs(BuildContext context, WidgetRef ref, List<int> ids) async {
  final choice = await pickFolder(context, ref);
  if (!choice.picked) return;
  await ref.read(dbProvider).moveDocuments(ids, choice.folderId);
  if (context.mounted) toast(context, '已移动 ${ids.length} 个文档');
}

Future<void> copyDocs(BuildContext context, WidgetRef ref, List<int> ids) async {
  final store = ref.read(storeProvider);
  for (final id in ids) {
    await store.copyDocument(id);
  }
  if (context.mounted) toast(context, '已复制 ${ids.length} 个文档');
}

/// Moves to the recycle bin (kept 30 days).
Future<bool> trashDocs(BuildContext context, WidgetRef ref, List<int> ids) async {
  final ok = await confirm(
    context,
    title: ids.length == 1 ? '删除文档？' : '删除 ${ids.length} 个文档？',
    message: '会先放进回收站，30 天后自动清除，期间可以恢复。',
    ok: '删除',
  );
  if (!ok) return false;
  await ref.read(dbProvider).trashDocuments(ids);
  if (context.mounted) toast(context, '已移到回收站');
  return true;
}

/// Locks when any of [docs] is unlocked, otherwise removes the lock.
/// Removing a lock asks for fingerprint or password first.
Future<void> toggleLock(BuildContext context, WidgetRef ref, List<Document> docs) async {
  final lock = docs.any((d) => !d.locked);
  if (lock) {
    if (!await ensureLockPassword(context, ref)) return;
  } else {
    if (!await unlock(context, ref, reason: '取消加锁')) return;
  }
  await ref.read(dbProvider).setLocked(docs.map((d) => d.id), lock);
  // A locked document must not stay readable through cached renderings.
  if (lock) {
    for (final d in docs) {
      await TempFiles.forgetDocument(d.id);
    }
  }
  if (context.mounted) toast(context, lock ? '已加锁' : '已取消加锁');
}

/// Joins the documents, in the order they were picked, into a new one and
/// opens it. The originals stay.
Future<void> mergeDocs(BuildContext context, WidgetRef ref, List<int> ids) async {
  if (ids.length < 2) return;
  final first = await ref.read(dbProvider).documentById(ids.first);
  if (!context.mounted) return;
  final title = await promptText(context, title: '合并后的文档名', initial: '${first?.title ?? '文档'} 等 ${ids.length} 个', maxLength: 200);
  if (title == null || !context.mounted) return;
  try {
    final id = await ref.read(storeProvider).mergeDocuments(ids, title: title);
    if (!context.mounted) return;
    toast(context, '已合并 ${ids.length} 个文档，原文档保留');
    context.push('/doc/$id');
  } catch (e) {
    if (context.mounted) toast(context, '合并失败：$e');
  }
}
