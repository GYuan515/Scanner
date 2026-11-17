import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../data/exporter.dart';
import '../data/temp_files.dart';
import 'library_actions.dart';

const mimePdf = 'application/pdf';
const mimeDocx = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
const mimeXlsx = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
const mimeJpeg = 'image/jpeg';

String fileSizeLabel(int b) =>
    b >= 1 << 20 ? '${(b / (1 << 20)).toStringAsFixed(1)} MB' : '${(b / 1024).toStringAsFixed(0)} KB';

/// Hands generated files to the user. One file: save it somewhere or share
/// it. Several: share them all.
Future<void> deliverFiles(BuildContext context, List<(String, Uint8List)> outputs, {String mime = mimePdf}) async {
  if (!context.mounted) return;
  if (outputs.isEmpty) {
    toast(context, '没有生成任何文件');
    return;
  }
  final dir = await TempFiles.dir('export');
  final files = <XFile>[];
  for (final (name, bytes) in outputs) {
    final f = File(p.join(dir.path, Exporter.safeName(name)));
    await f.writeAsBytes(bytes, flush: true);
    files.add(XFile(f.path, mimeType: mime));
  }
  if (!context.mounted) return;
  if (outputs.length > 1) {
    await SharePlus.instance.share(ShareParams(files: files));
    return;
  }
  final (name, bytes) = outputs.single;
  final choice = await showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Wrap(children: [
        ListTile(title: Text(name), subtitle: Text(fileSizeLabel(bytes.length))),
        ListTile(leading: const Icon(Icons.save_alt), title: const Text('保存到…'), onTap: () => Navigator.pop(ctx, 'save')),
        ListTile(leading: const Icon(Icons.ios_share), title: const Text('分享 / 用其他应用打开'), onTap: () => Navigator.pop(ctx, 'share')),
      ]),
    ),
  );
  if (choice == 'save') {
    final uri = await FilePicker.saveFile(fileName: Exporter.safeName(name), bytes: bytes, mimeType: mime);
    if (uri != null && context.mounted) toast(context, '已保存');
  } else if (choice == 'share') {
    await SharePlus.instance.share(ShareParams(files: files));
  }
}

/// Runs [task] behind a modal progress dialog that shows the messages it
/// reports. Returns the task's result; errors are rethrown after the
/// dialog closed.
Future<T> runWithProgress<T>(BuildContext context, String title, Future<T> Function(void Function(String) progress) task) async {
  final message = ValueNotifier<String>('准备中…');
  final nav = Navigator.of(context, rootNavigator: true);
  var open = true;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(title),
        content: Row(children: [
          const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3)),
          const SizedBox(width: 16),
          Expanded(child: ValueListenableBuilder<String>(valueListenable: message, builder: (_, m, _) => Text(m))),
        ]),
      ),
    ),
  ).whenComplete(() => open = false);
  try {
    return await task((m) => message.value = m);
  } finally {
    if (open) nav.pop();
    // Disposed after the dialog's exit animation, which still listens.
    Future<void>.delayed(const Duration(seconds: 1), message.dispose);
  }
}
