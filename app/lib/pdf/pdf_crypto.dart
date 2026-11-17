import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

// The encryption dictionary has to be built from the pdf package's object
// classes, which it does not export; pdf_crypto_test fails if they move.
// ignore_for_file: implementation_imports
import 'package:crypto/crypto.dart' as crypto;
import 'package:pdf/pdf.dart';
import 'package:pdf/src/pdf/format/dict.dart';
import 'package:pdf/src/pdf/format/num.dart';
import 'package:pdf/src/pdf/format/object_base.dart';
import 'package:pdf/src/pdf/format/string.dart';
import 'package:pointycastle/export.dart';

/// PDF password protection: AES-256, standard security handler revision 6
/// (ISO 32000-2, also read by every PDF 1.7 viewer with the Adobe
/// extension level 3).
///
/// Only the open password is set; the owner password is random, so nobody
/// can change permissions, and all permissions are granted to whoever
/// knows the open password.
class Aes256Encryption extends PdfEncryption {
  Aes256Encryption(super.pdfDocument, String password, {math.Random? random})
      : _random = random ?? math.Random.secure() {
    _fileKey = _bytes(32);
    final user = _passwordBytes(password);
    final owner = _bytes(32);

    // U: hash(user, validation salt) + validation salt + key salt.
    final uvs = _bytes(8), uks = _bytes(8);
    final u = Uint8List.fromList([...hashR6(user, uvs, Uint8List(0)), ...uvs, ...uks]);
    final ue = _aesCbc(hashR6(user, uks, Uint8List(0)), Uint8List(16), _fileKey, encrypt: true);

    // O: same, with U as extra input.
    final ovs = _bytes(8), oks = _bytes(8);
    final o = Uint8List.fromList([...hashR6(owner, ovs, u), ...ovs, ...oks]);
    final oe = _aesCbc(hashR6(owner, oks, u), Uint8List(16), _fileKey, encrypt: true);

    // Perms: P (little endian), FFFFFFFF, 'T' (metadata encrypted), "adb", 4 random bytes; AES-256-ECB.
    const p = -4; // every permission
    final perms = Uint8List(16)
      ..buffer.asByteData().setInt32(0, p, Endian.little)
      ..setAll(4, [0xFF, 0xFF, 0xFF, 0xFF])
      ..setAll(8, utf8.encode('Tadb'))
      ..setAll(12, _bytes(4));
    final permsEnc = _aesEcb(_fileKey, perms);

    params
      ..['/Filter'] = const PdfName('/Standard')
      ..['/V'] = const PdfNum(5)
      ..['/R'] = const PdfNum(6)
      ..['/Length'] = const PdfNum(256)
      ..['/P'] = const PdfNum(p)
      ..['/O'] = _str(o)
      ..['/U'] = _str(u)
      ..['/OE'] = _str(oe)
      ..['/UE'] = _str(ue)
      ..['/Perms'] = _str(permsEnc)
      ..['/CF'] = PdfDict({
        '/StdCF': PdfDict({
          '/AuthEvent': const PdfName('/DocOpen'),
          '/CFM': const PdfName('/AESV3'),
          '/Length': const PdfNum(32),
        }),
      })
      ..['/StmF'] = const PdfName('/StdCF')
      ..['/StrF'] = const PdfName('/StdCF');
  }

  final math.Random _random;
  late final Uint8List _fileKey;

  /// AESV3: every string and stream is AES-256-CBC with the file key, a
  /// fresh random IV in front and PKCS#7 padding.
  @override
  Uint8List encrypt(Uint8List input, PdfObjectBase object) {
    final iv = _bytes(16);
    final pad = 16 - input.length % 16;
    final padded = Uint8List(input.length + pad)
      ..setAll(0, input)
      ..fillRange(input.length, input.length + pad, pad);
    final enc = _aesCbc(_fileKey, iv, padded, encrypt: true);
    // Typed copies only: spreading into a List<int> costs ~8x the size.
    return Uint8List(16 + enc.length)
      ..setRange(0, 16, iv)
      ..setRange(16, 16 + enc.length, enc);
  }

  Uint8List _bytes(int n) => Uint8List.fromList(List.generate(n, (_) => _random.nextInt(256)));

  static PdfString _str(Uint8List b) => PdfString(b, format: PdfStringFormat.binary, encrypted: false);

  /// UTF-8, truncated to 127 bytes as the spec requires. (SASLprep is
  /// skipped; it only changes unusual Unicode input.)
  static Uint8List _passwordBytes(String pw) {
    final b = utf8.encode(pw);
    return Uint8List.fromList(b.length > 127 ? b.sublist(0, 127) : b);
  }

  /// Algorithm 2.B: the iterated SHA-2 / AES hash of revision 6.
  static Uint8List hashR6(Uint8List password, Uint8List salt, Uint8List udata) {
    var k = Uint8List.fromList(crypto.sha256.convert([...password, ...salt, ...udata]).bytes);
    for (var round = 0;; round++) {
      final block = [...password, ...k, ...udata];
      final k1 = Uint8List(block.length * 64);
      for (var i = 0; i < 64; i++) {
        k1.setAll(i * block.length, block);
      }
      final e = _aesCbc(k.sublist(0, 16), k.sublist(16, 32), k1, encrypt: true);
      var sum = 0;
      for (var i = 0; i < 16; i++) {
        sum += e[i];
      }
      final hash = switch (sum % 3) {
        0 => crypto.sha256,
        1 => crypto.sha384,
        _ => crypto.sha512,
      };
      k = Uint8List.fromList(hash.convert(e).bytes);
      if (round >= 63 && e.last <= round - 31) break;
    }
    return k.sublist(0, 32);
  }

  /// Raw AES-CBC (no padding; [data] is a multiple of 16 bytes).
  static Uint8List _aesCbc(Uint8List key, Uint8List iv, Uint8List data, {required bool encrypt}) {
    final c = CBCBlockCipher(AESEngine())..init(encrypt, ParametersWithIV(KeyParameter(key), iv));
    final out = Uint8List(data.length);
    for (var off = 0; off < data.length; off += 16) {
      c.processBlock(data, off, out, off);
    }
    return out;
  }

  static Uint8List _aesEcb(Uint8List key, Uint8List block) {
    final c = AESEngine()..init(true, KeyParameter(key));
    final out = Uint8List(16);
    c.processBlock(block, 0, out, 0);
    return out;
  }
}
