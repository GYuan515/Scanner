import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

import '../app_state.dart';
import '../data/app_lock.dart';
import '../data/db.dart';

Future<String?> promptText(
  BuildContext context, {
  required String title,
  String initial = '',
  String? hint,
  int maxLength = 120,
  String ok = '确定',
}) async {
  final result = await showDialog<String>(
    context: context,
    builder: (_) => _TextInputDialog(title: title, initial: initial, hint: hint, maxLength: maxLength, ok: ok, trim: true),
  );
  return (result == null || result.isEmpty) ? null : result;
}

/// A one-field input dialog that owns its controller.
///
/// Why a widget and not a local controller in the caller: showDialog's
/// future completes when the route is popped, but the dialog keeps
/// rebuilding through its exit animation. Disposing a caller-owned
/// controller at that point crashes with "TextEditingController was used
/// after being disposed" and then `_dependents.isEmpty`. State.dispose runs
/// only after the route is gone.
class _TextInputDialog extends StatefulWidget {
  const _TextInputDialog({
    required this.title,
    this.initial = '',
    this.hint,
    this.label,
    this.error,
    this.maxLength,
    this.ok = '确定',
    this.obscure = false,
    this.trim = false,
  });

  final String title;
  final String initial;
  final String? hint;
  final String? label;
  final String? error;
  final int? maxLength;
  final String ok;
  final bool obscure;
  final bool trim;

  @override
  State<_TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<_TextInputDialog> {
  late final _ctrl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, widget.trim ? _ctrl.text.trim() : _ctrl.text);

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: TextField(
          controller: _ctrl,
          autofocus: true,
          obscureText: widget.obscure,
          maxLength: widget.maxLength,
          decoration: InputDecoration(hintText: widget.hint, labelText: widget.label, errorText: widget.error),
          onSubmitted: (_) => _submit(),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(onPressed: _submit, child: Text(widget.ok)),
        ],
      );
}

Future<bool> confirm(BuildContext context, {required String title, String? message, String ok = '确定'}) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: message == null ? null : Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ok)),
        ],
      ),
    ) ==
    true;

void toast(BuildContext context, String msg) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

/// Result of [pickFolder]: `picked` is false when cancelled; `folderId`
/// null means the top level.
typedef FolderChoice = ({bool picked, int? folderId});

/// Lets the user choose a destination folder from the whole tree.
Future<FolderChoice> pickFolder(BuildContext context, WidgetRef ref, {String title = '移动到'}) async {
  final folders = await ref.read(dbProvider).watchAllFolders().first;
  // Flatten the tree depth-first so children sit under their parent.
  final children = <int?, List<Folder>>{};
  for (final f in folders) {
    children.putIfAbsent(f.parentId, () => []).add(f);
  }
  final rows = <(Folder, int)>[];
  void walk(int? parent, int depth) {
    for (final f in children[parent] ?? const <Folder>[]) {
      rows.add((f, depth));
      walk(f.id, depth + 1);
    }
  }

  walk(null, 0);
  if (!context.mounted) return (picked: false, folderId: null);
  final picked = await showDialog<int>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: Text(title),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.pop(ctx, -1),
          child: const ListTile(leading: Icon(Icons.home_outlined), title: Text('我的文档（顶层）')),
        ),
        for (final (f, depth) in rows)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, f.id),
            child: Padding(
              padding: EdgeInsets.only(left: 16.0 * depth),
              child: ListTile(leading: const Icon(Icons.folder_outlined), title: Text(f.name)),
            ),
          ),
      ],
    ),
  );
  if (picked == null) return (picked: false, folderId: null);
  return (picked: true, folderId: picked == -1 ? null : picked);
}

/// Edits tags. For one document the chips show its current tags and the
/// result replaces them; for several documents the chosen tags are added.
Future<void> editTags(BuildContext context, WidgetRef ref, List<int> docIds) async {
  final db = ref.read(dbProvider);
  final single = docIds.length == 1;
  final initial = single ? (await db.tagIdsOf(docIds.single)).toSet() : <int>{};
  if (!context.mounted) return;
  final chosen = await showModalBottomSheet<Set<int>>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _TagSheet(initial: initial, title: single ? '标签' : '给 ${docIds.length} 个文档添加标签'),
  );
  if (chosen == null) return;
  if (single) {
    await db.setTags(docIds, chosen);
  } else {
    for (final t in chosen) {
      await db.addTag(docIds, t);
    }
  }
}

class _TagSheet extends ConsumerStatefulWidget {
  const _TagSheet({required this.initial, required this.title});
  final Set<int> initial;
  final String title;

  @override
  ConsumerState<_TagSheet> createState() => _TagSheetState();
}

class _TagSheetState extends ConsumerState<_TagSheet> {
  late final Set<int> _sel = {...widget.initial};
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final name = _ctrl.text.trim();
    if (name.isEmpty) return;
    final id = await ref.read(dbProvider).ensureTag(name.length > 40 ? name.substring(0, 40) : name);
    _ctrl.clear();
    setState(() => _sel.add(id));
  }

  @override
  Widget build(BuildContext context) {
    final tags = ref.watch(tagsProvider).value ?? const <Tag>[];
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(widget.title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        if (tags.isEmpty) const Text('还没有标签，在下面新建一个'),
        Wrap(spacing: 8, runSpacing: 4, children: [
          for (final t in tags)
            FilterChip(
              label: Text(t.name),
              selected: _sel.contains(t.id),
              onSelected: (on) => setState(() => on ? _sel.add(t.id) : _sel.remove(t.id)),
            ),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _ctrl,
              maxLength: 40,
              decoration: const InputDecoration(hintText: '新标签名'),
              onSubmitted: (_) => _add(),
            ),
          ),
          IconButton(onPressed: _add, icon: const Icon(Icons.add)),
        ]),
        SizedBox(
          width: double.infinity,
          child: FilledButton(onPressed: () => Navigator.pop(context, _sel), child: const Text('完成')),
        ),
      ]),
    );
  }
}

// ------------------------------------------------------------------- locking

/// Makes sure an app password exists before something gets locked.
/// Returns false if the user cancelled.
Future<bool> ensureLockPassword(BuildContext context, WidgetRef ref) async {
  final lock = ref.read(appLockProvider);
  if (await lock.hasPassword()) return true;
  if (!context.mounted) return false;
  return setLockPassword(context, ref, intro: '第一次加锁，先设置一个密码。指纹可用时会优先用指纹解锁，密码作为备用。');
}

Future<bool> setLockPassword(BuildContext context, WidgetRef ref, {String? intro}) async {
  final pw = await showDialog<String>(context: context, builder: (_) => _NewPasswordDialog(intro: intro));
  if (pw == null) return false;
  await ref.read(appLockProvider).setPassword(pw);
  if (context.mounted) toast(context, '密码已设置');
  return true;
}

/// Changing the password requires the current one.
Future<void> changeLockPassword(BuildContext context, WidgetRef ref) async {
  final lock = ref.read(appLockProvider);
  if (await lock.hasPassword()) {
    if (!context.mounted) return;
    final old = await _askPassword(context, title: '输入当前密码');
    if (old == null) return;
    if (!await lock.verify(old)) {
      if (context.mounted) toast(context, '密码不对');
      return;
    }
  }
  if (context.mounted) await setLockPassword(context, ref);
}

/// Fingerprint (or face) first when the phone supports it, otherwise or
/// on failure the app password. Returns true when unlocked.
Future<bool> unlock(BuildContext context, WidgetRef ref, {String reason = '解锁文档'}) async {
  final lock = ref.read(appLockProvider);
  if (!await lock.hasPassword()) return true; // nothing was ever locked with a password
  final auth = LocalAuthentication();
  try {
    if (await auth.isDeviceSupported() && await auth.canCheckBiometrics) {
      if (await auth.authenticate(localizedReason: reason, biometricOnly: true)) return true;
    }
  } catch (_) {
    // Biometric unavailable or cancelled: fall back to the password.
  }
  if (!context.mounted) return false;
  for (var attempt = 0; attempt < 5; attempt++) {
    final pw = await _askPassword(context, title: reason, error: attempt > 0 ? '密码不对，再试一次' : null);
    if (pw == null) return false;
    if (await lock.verify(pw)) return true;
    if (!context.mounted) return false;
  }
  return false;
}

/// Asks for a password: hidden while typing and not trimmed (spaces can be
/// part of a password).
Future<String?> askPassword(BuildContext context, {required String title, String? error}) => _askPassword(context, title: title, error: error);

Future<String?> _askPassword(BuildContext context, {required String title, String? error}) => showDialog<String>(
      context: context,
      builder: (_) => _TextInputDialog(title: title, label: '密码', error: error, obscure: true),
    );

class _NewPasswordDialog extends StatefulWidget {
  const _NewPasswordDialog({this.intro});
  final String? intro;

  @override
  State<_NewPasswordDialog> createState() => _NewPasswordDialogState();
}

class _NewPasswordDialogState extends State<_NewPasswordDialog> {
  final _a = TextEditingController(), _b = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _a.dispose();
    _b.dispose();
    super.dispose();
  }

  void _submit() {
    if (_a.text.length < AppLock.minLength) {
      setState(() => _error = '至少 ${AppLock.minLength} 位');
    } else if (_a.text != _b.text) {
      setState(() => _error = '两次输入不一致');
    } else {
      Navigator.pop(context, _a.text);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('设置密码'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          if (widget.intro != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(widget.intro!)),
          TextField(controller: _a, autofocus: true, obscureText: true, decoration: const InputDecoration(labelText: '新密码')),
          TextField(
            controller: _b,
            obscureText: true,
            decoration: InputDecoration(labelText: '再输一次', errorText: _error),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 8),
          const Text('忘记密码将无法打开已加锁的文档。加锁只拦住打开操作，图片文件本身没有加密。', style: TextStyle(fontSize: 12)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(onPressed: _submit, child: const Text('确定')),
        ],
      );
}
