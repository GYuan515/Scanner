import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app_state.dart';
import 'library_actions.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late bool _autoOcr = ref.read(ocrQueueProvider).auto;

  Future<void> _setAutoOcr(bool v) async {
    setState(() => _autoOcr = v);
    final queue = ref.read(ocrQueueProvider)..auto = v;
    await ref.read(dbProvider).setSetting(ocrAutoKey, v ? '1' : '0');
    if (v) queue.request(const []); // pick up pages that waited while it was off
  }

  @override
  Widget build(BuildContext context) {
    final pending = ref.watch(ocrPendingProvider).value ?? 0;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(children: [
        SwitchListTile(
          secondary: const Icon(Icons.text_snippet_outlined),
          title: const Text('自动识别文字'),
          subtitle: Text(_autoOcr
              ? (pending > 0 ? '还有 $pending 页等待识别' : '扫描后在后台识别，识别后可以按内容搜索')
              : '关闭后，打开某页的“文字”或导出时才识别'),
          value: _autoOcr,
          onChanged: _setAutoOcr,
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.password),
          title: const Text('加锁密码'),
          onTap: () => changeLockPassword(context, ref),
        ),
        ListTile(
          leading: const Icon(Icons.build_outlined),
          title: const Text('组件自检'),
          subtitle: const Text('OpenCV、ONNX Runtime、PDFium、文字识别、二维码，以及错误日志'),
          onTap: () => context.push('/diagnostics'),
        ),
      ]),
    );
  }
}
