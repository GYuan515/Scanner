import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../scan/codes.dart';
import 'library_actions.dart';

/// Bottom sheet listing codes read from an image or the camera.
Future<void> showCodes(BuildContext context, List<FoundCode> codes) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
          child: codes.isEmpty
              ? const Padding(padding: EdgeInsets.all(32), child: Text('没有找到二维码或条码', textAlign: TextAlign.center))
              : ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  itemCount: codes.length,
                  separatorBuilder: (_, _) => const Divider(),
                  itemBuilder: (_, i) => CodeTile(code: codes[i]),
                ),
        ),
      ),
    );

class CodeTile extends StatelessWidget {
  const CodeTile({super.key, required this.code});
  final FoundCode code;

  Future<void> _open(BuildContext context) async {
    var t = code.text.trim();
    if (!t.contains('://')) t = 'https://$t';
    final uri = Uri.tryParse(t);
    final ok = uri != null && await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) toast(context, '无法打开这个链接');
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(code.format, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 4),
        SelectableText(code.text, style: Theme.of(context).textTheme.bodyLarge),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          FilledButton.tonalIcon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: code.text));
              if (context.mounted) toast(context, '已复制');
            },
            icon: const Icon(Icons.copy),
            label: const Text('复制'),
          ),
          if (code.isUrl)
            FilledButton.tonalIcon(onPressed: () => _open(context), icon: const Icon(Icons.open_in_new), label: const Text('打开')),
          FilledButton.tonalIcon(
            onPressed: () => SharePlus.instance.share(ShareParams(text: code.text)),
            icon: const Icon(Icons.share),
            label: const Text('分享'),
          ),
        ]),
      ]);
}
