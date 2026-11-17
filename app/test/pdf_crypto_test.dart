import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:doc_scanner/pdf/pdf_crypto.dart';

void main() {
  test('writes an AES-256 encrypted PDF', () async {
    final doc = pw.Document();
    doc.addPage(pw.Page(build: (_) => pw.Text('secret page 42')));
    doc.document.encryption = Aes256Encryption(doc.document, '密码1234');
    final bytes = await doc.save();
    final s = String.fromCharCodes(bytes);
    expect(s, contains('/AESV3'));
    expect(s, isNot(contains('secret page 42')));
    Directory('build').createSync(recursive: true);
    File('build/encrypted_test.pdf').writeAsBytesSync(bytes);
  });
}
