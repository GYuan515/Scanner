import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

/// Asks for [permission] if needed. Returns true when it is granted (or
/// limited, for photos). On a permanent denial it offers to open the
/// system settings page, since the OS will not show the prompt again.
Future<bool> ensurePermission(BuildContext context, Permission permission, String what) async {
  var status = await permission.status;
  if (status.isGranted || status.isLimited) return true;
  if (!status.isPermanentlyDenied) {
    status = await permission.request();
    if (status.isGranted || status.isLimited) return true;
  }
  if (!context.mounted) return false;
  if (status.isPermanentlyDenied || status.isRestricted) {
    final open = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('需要$what权限'),
        content: Text('$what权限已被关闭，请在系统设置中允许后再试。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('去设置')),
        ],
      ),
    );
    if (open == true) await openAppSettings();
  } else {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('没有$what权限')));
  }
  return false;
}
