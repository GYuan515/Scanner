import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'docx_writer.dart';
import 'table.dart';

/// A sheet to write: a table grid with a name.
class SheetData {
  SheetData(this.name, this.grid);
  final String name;
  final TableGrid grid;
}

/// Writes tables as a .xlsx (SpreadsheetML): one sheet per table, merged
/// cells kept, plain numbers stored as numbers.
class XlsxWriter {
  static Uint8List write(List<SheetData> sheets) {
    if (sheets.isEmpty) throw ArgumentError('没有表格');
    final names = _uniqueNames(sheets.map((s) => s.name).toList());
    final archive = Archive();
    void add(String path, String xml) {
      final bytes = utf8.encode(xml);
      archive.addFile(ArchiveFile(path, bytes.length, bytes));
    }

    final overrides = StringBuffer(), wbSheets = StringBuffer(), wbRels = StringBuffer();
    for (var i = 0; i < sheets.length; i++) {
      final n = i + 1;
      overrides.write('<Override PartName="/xl/worksheets/sheet$n.xml" '
          'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>');
      wbSheets.write('<sheet name="${DocxWriter.esc(names[i])}" sheetId="$n" r:id="rId$n"/>');
      wbRels.write('<Relationship Id="rId$n" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" '
          'Target="worksheets/sheet$n.xml"/>');
      add('xl/worksheets/sheet$n.xml', _sheet(sheets[i].grid));
    }
    final stylesId = sheets.length + 1;
    wbRels.write('<Relationship Id="rId$stylesId" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" '
        'Target="styles.xml"/>');

    add('[Content_Types].xml', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
        '$overrides</Types>');
    add('_rels/.rels', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
        '</Relationships>');
    add('xl/workbook.xml', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>$wbSheets</sheets></workbook>');
    add('xl/_rels/workbook.xml.rels', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">$wbRels</Relationships>');
    add('xl/styles.xml', _styles);
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  /// Excel sheet names: at most 31 characters, none of []:*?/\, unique.
  static List<String> _uniqueNames(List<String> raw) {
    final used = <String>{};
    return [
      for (final r in raw)
        () {
          var base = r.replaceAll(RegExp(r'[\[\]:*?/\\]'), '_').trim();
          if (base.isEmpty) base = '表格';
          if (base.length > 28) base = base.substring(0, 28);
          var name = base;
          for (var k = 2; used.contains(name.toLowerCase()); k++) {
            name = '$base($k)';
          }
          used.add(name.toLowerCase());
          return name;
        }(),
    ];
  }

  /// A1-style column letters.
  static String col(int c) {
    var n = c + 1, s = '';
    while (n > 0) {
      final m = (n - 1) % 26;
      s = String.fromCharCode(65 + m) + s;
      n = (n - 1) ~/ 26;
    }
    return s;
  }

  /// Plain numbers ("120", "-3.5", "1,280.50") become numeric cells;
  /// anything else (leading zeros, units, percentages, dates) stays text.
  static num? numberOf(String text) {
    final t = text.trim();
    if (!RegExp(r'^-?(\d{1,3}(,\d{3})+|\d+)(\.\d+)?$').hasMatch(t)) return null;
    if (RegExp(r'^-?0\d').hasMatch(t)) return null; // codes like 0123
    final digits = t.replaceAll(RegExp(r'\D'), '');
    // Excel keeps 15 significant digits; ID-card, bank-card, phone and
    // order numbers (11+ digits without thousands separators) are text.
    if (digits.length > 15) return null;
    if (!t.contains(',') && t.split('.').first.replaceAll('-', '').length >= 11) return null;
    return num.tryParse(t.replaceAll(',', ''));
  }

  static double _textWidth(String s) {
    var w = 0.0;
    for (final r in s.runes) {
      w += r > 0x2E80 ? 2.1 : 1.1;
    }
    return w;
  }

  static String _sheet(TableGrid g) {
    final at = <(int, int), TableCell>{for (final c in g.cells) (c.row, c.col): c};
    final cols = g.cols < 1 ? 1 : g.cols;
    final widths = List<double>.filled(cols, 8);
    for (final c in g.cells) {
      if (c.colSpan == 1 && c.col < g.cols) widths[c.col] = math.max(widths[c.col], math.min(60, _textWidth(c.text) + 2));
    }
    final sb = StringBuffer('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><cols>');
    for (var c = 0; c < cols; c++) {
      sb.write('<col min="${c + 1}" max="${c + 1}" width="${widths[c].toStringAsFixed(1)}" customWidth="1"/>');
    }
    sb.write('</cols><sheetData>');
    // Covered positions of merged cells still get the border style.
    final covered = <(int, int)>{};
    for (final c in g.cells) {
      for (var r = c.row; r < c.row + c.rowSpan; r++) {
        for (var k = c.col; k < c.col + c.colSpan; k++) {
          covered.add((r, k));
        }
      }
    }
    for (var r = 0; r < g.rows; r++) {
      sb.write('<row r="${r + 1}">');
      for (var c = 0; c < g.cols; c++) {
        final ref = '${col(c)}${r + 1}';
        final cell = at[(r, c)];
        if (cell == null) {
          if (covered.contains((r, c))) sb.write('<c r="$ref" s="1"/>');
          continue;
        }
        final n = numberOf(cell.text);
        if (n != null) {
          sb.write('<c r="$ref" s="1"><v>$n</v></c>');
        } else if (cell.text.isEmpty) {
          sb.write('<c r="$ref" s="1"/>');
        } else {
          sb.write('<c r="$ref" s="1" t="inlineStr"><is><t xml:space="preserve">${DocxWriter.esc(cell.text)}</t></is></c>');
        }
      }
      sb.write('</row>');
    }
    sb.write('</sheetData>');
    final merges = [for (final c in g.cells) if (c.rowSpan > 1 || c.colSpan > 1) c];
    if (merges.isNotEmpty) {
      sb.write('<mergeCells count="${merges.length}">');
      for (final c in merges) {
        sb.write('<mergeCell ref="${col(c.col)}${c.row + 1}:${col(c.col + c.colSpan - 1)}${c.row + c.rowSpan}"/>');
      }
      sb.write('</mergeCells>');
    }
    sb.write('</worksheet>');
    return sb.toString();
  }

  /// Style 0 = default; style 1 = thin borders, wrapped, vertically centred.
  static const _styles = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
      '<fonts count="1"><font><sz val="11"/><name val="等线"/><charset val="134"/></font></fonts>'
      '<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>'
      '<borders count="2"><border><left/><right/><top/><bottom/><diagonal/></border>'
      '<border><left style="thin"><color auto="1"/></left><right style="thin"><color auto="1"/></right>'
      '<top style="thin"><color auto="1"/></top><bottom style="thin"><color auto="1"/></bottom><diagonal/></border></borders>'
      '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
      '<cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
      '<xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1">'
      '<alignment vertical="center" wrapText="1"/></xf></cellXfs>'
      '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
      '</styleSheet>';
}
