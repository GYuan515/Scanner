import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';

import '../app_state.dart';
import '../convert/converter.dart';
import '../convert/doc_model.dart';
import '../data/db.dart';
import '../data/exporter.dart';
import '../data/temp_files.dart';
import '../ocr/ocr_service.dart';
import 'deliver.dart';
import 'library_actions.dart';

enum ConvertTarget {
  word('Word', 'docx', mimeDocx),
  excel('Excel', 'xlsx', mimeXlsx);

  const ConvertTarget(this.label, this.ext, this.mime);
  final String label;
  final String ext;
  final String mime;
}

Future<DocumentConverter> _converter(WidgetRef ref) async {
  // A worker that died stays cached; start a fresh one.
  final current = await ref.read(ocrEngineProvider.future);
  if (current is OcrService && current.isClosed) ref.invalidate(ocrEngineProvider);
  return DocumentConverter(layout: await ref.read(layoutEngineProvider.future), ocr: await ref.read(ocrEngineProvider.future));
}

/// Writes the file inside the progress dialog; returns (bytes, note).
Future<(Uint8List, String?)> _generate(ConvertTarget target, String title, List<PageInput> pages, void Function(String) progress) async {
  progress('正在生成 ${target.label} 文件…');
  if (target == ConvertTarget.word) return (await DocumentConverter.toDocx(pages, title: title), null);
  final (xlsx, tables) = await DocumentConverter.toXlsx(pages);
  return (xlsx, tables == 0 ? '没有找到表格，已按行导出文字' : null);
}

Future<void> _deliver(BuildContext context, ConvertTarget target, String title, (Uint8List, String?) result) async {
  final (bytes, note) = result;
  if (note != null) toast(context, note);
  await deliverFiles(context, [(Exporter.safeName('$title.${target.ext}'), bytes)], mime: target.mime);
}

/// Converts an app document (its scanned pages) to Word or Excel.
Future<void> convertDocument(BuildContext context, WidgetRef ref, Document doc, List<ScanPage> pages, ConvertTarget target) async {
  final store = ref.read(storeProvider);
  final queue = ref.read(ocrQueueProvider);
  try {
    final converter = await _converter(ref);
    if (!context.mounted) return;
    // Analysis and file writing both happen behind the dialog, so nothing
    // can be started twice meanwhile.
    final result = await runWithProgress(context, '转为 ${target.label}', (progress) async {
      final analyzed = await converter.fromScans(pages, store, queue, progress);
      return _generate(target, doc.title, analyzed, progress);
    });
    if (context.mounted) await _deliver(context, target, doc.title, result);
  } catch (e) {
    if (context.mounted) toast(context, '转换失败：$e');
  }
}

/// Converts an opened PDF to Word or Excel.
Future<void> convertPdf(BuildContext context, WidgetRef ref, PdfDocument pdf, String title, ConvertTarget target) async {
  final work = await TempFiles.dir('convert');
  try {
    final converter = await _converter(ref);
    if (!context.mounted) return;
    final result = await runWithProgress(context, '转为 ${target.label}', (progress) async {
      final analyzed = await converter.fromPdf(pdf, work, progress);
      return _generate(target, title, analyzed, progress);
    });
    if (context.mounted) await _deliver(context, target, title, result);
  } catch (e) {
    if (context.mounted) toast(context, '转换失败：$e');
  } finally {
    // Rendered page images are only needed during the conversion.
    for (final f in work.listSync().whereType<File>()) {
      try {
        f.deleteSync();
      } on FileSystemException {
        // in use or gone
      }
    }
  }
}
