import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'db.dart';

/// The app password that guards locked documents.
///
/// Only a salted PBKDF2-HMAC-SHA256 hash is stored (in the settings
/// table). Locking hides a document behind a prompt; the image files
/// themselves are not encrypted.
class AppLock {
  AppLock(this.db);
  final AppDatabase db;

  static const _hashKey = 'lock.hash';
  static const _saltKey = 'lock.salt';
  static const _iterKey = 'lock.iterations';
  static const defaultIterations = 60000;
  static const minLength = 4;

  Future<bool> hasPassword() async => await db.getSetting(_hashKey) != null;

  Future<void> setPassword(String password, {int iterations = defaultIterations}) async {
    if (password.length < minLength) throw ArgumentError('密码至少 $minLength 位');
    final rnd = Random.secure();
    final salt = Uint8List.fromList(List.generate(16, (_) => rnd.nextInt(256)));
    final hash = await _pbkdf2InBackground(utf8.encode(password), salt, iterations);
    await db.transaction(() async {
      await db.setSetting(_saltKey, base64.encode(salt));
      await db.setSetting(_iterKey, '$iterations');
      await db.setSetting(_hashKey, base64.encode(hash));
    });
  }

  Future<bool> verify(String password) async {
    final hash = await db.getSetting(_hashKey);
    final salt = await db.getSetting(_saltKey);
    final iter = int.tryParse(await db.getSetting(_iterKey) ?? '');
    if (hash == null || salt == null || iter == null) return false;
    final got = await _pbkdf2InBackground(utf8.encode(password), base64.decode(salt), iter);
    return _constantTimeEquals(got, base64.decode(hash));
  }

  /// RFC 8018 PBKDF2 with HMAC-SHA256.
  static Uint8List pbkdf2(List<int> password, List<int> salt, int iterations, int length) {
    final hmac = Hmac(sha256, password);
    final out = BytesBuilder();
    for (var block = 1; out.length < length; block++) {
      final blockIndex = [block >> 24 & 0xff, block >> 16 & 0xff, block >> 8 & 0xff, block & 0xff];
      var u = hmac.convert([...salt, ...blockIndex]).bytes;
      final t = Uint8List.fromList(u);
      for (var i = 1; i < iterations; i++) {
        u = hmac.convert(u).bytes;
        for (var j = 0; j < t.length; j++) {
          t[j] ^= u[j];
        }
      }
      out.add(t);
    }
    return Uint8List.sublistView(out.takeBytes(), 0, length);
  }

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

// Top-level so the isolate closure captures only its arguments (see
// scan/background.dart for why that matters).
Future<Uint8List> _pbkdf2InBackground(List<int> password, List<int> salt, int iterations) =>
    Isolate.run(() => AppLock.pbkdf2(password, salt, iterations, 32));
