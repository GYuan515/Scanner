import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Appends uncaught errors to `<app documents>/logs/errors.log`.
///
/// Some phones (vivo) rate-limit logcat and drop Flutter's stack traces,
/// so errors are also kept in a file that the diagnostics screen shows
/// and `adb shell run-as` can read.
class ErrorLog {
  ErrorLog._(this.file);

  final File file;
  static ErrorLog? instance;

  /// The file is trimmed to the newest half once it passes this size.
  static const maxBytes = 256 * 1024;

  static Future<void> install() async {
    final dir = Directory(p.join((await getApplicationDocumentsDirectory()).path, 'logs'));
    await dir.create(recursive: true);
    final log = ErrorLog._(File(p.join(dir.path, 'errors.log')));
    instance = log;

    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      log.write('FlutterError', details.exceptionAsString(), details.stack);
      previous?.call(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      log.write('Uncaught', '$error', stack);
      return false; // keep the default handling (prints to the console)
    };
  }

  void write(String kind, String message, StackTrace? stack) {
    try {
      final entry = StringBuffer()
        ..writeln('==== ${DateTime.now().toIso8601String()} $kind')
        ..writeln(message)
        ..writeln(stack ?? '(no stack)');
      file.writeAsStringSync(entry.toString(), mode: FileMode.append, flush: true);
      if (file.lengthSync() > maxBytes) {
        final text = file.readAsStringSync();
        file.writeAsStringSync(text.substring(text.length ~/ 2));
      }
    } catch (_) {
      // Logging must never throw on top of the original error.
    }
  }

  String read() => file.existsSync() ? file.readAsStringSync() : '';

  void clear() {
    if (file.existsSync()) file.deleteSync();
  }
}
