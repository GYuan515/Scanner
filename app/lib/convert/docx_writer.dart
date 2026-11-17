import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'doc_model.dart';
import 'table.dart';

/// Writes [DocBlock]s as a .docx (Office Open XML): a zip of XML parts.
class DocxWriter {
  // A4 portrait, 2 cm margins, in twentieths of a point.
  static const _pageW = 11906, _pageH = 16838, _margin = 1134;
  static const _textWidthTwips = _pageW - 2 * _margin;
  static const _emuPerTwip = 635;

  static Uint8List write(List<DocBlock> blocks, {String title = ''}) {
    final media = <String, Uint8List>{};
    final rels = <String>[];
    final body = StringBuffer();
    var imageId = 0;

    for (final b in blocks) {
      switch (b) {
        case HeadingBlock(:final text, :final level):
          body.write(_p(text, style: 'Heading$level'));
        case ParagraphBlock(:final text, :final caption, :final indent):
          body.write(_p(text, style: caption ? 'Caption' : null, firstLineIndent: indent));
        case TableBlock(:final grid, :final widthFraction):
          body
            ..write(_table(grid, widthFraction))
            // Word needs a paragraph between consecutive tables.
            ..write('<w:p/>');
        case ImageBlock(:final jpeg, :final width, :final height, :final widthFraction):
          imageId++;
          final name = 'image$imageId.jpeg';
          media[name] = jpeg;
          final rid = 'rIdImg$imageId';
          rels.add('<Relationship Id="$rid" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/$name"/>');
          var cx = (_textWidthTwips * widthFraction.clamp(0.1, 1.0) * _emuPerTwip).round();
          var cy = (cx * height / width).round();
          // A tall figure must still fit on one page.
          const maxCy = (_pageH - 2 * _margin - 600) * _emuPerTwip;
          if (cy > maxCy) {
            cx = (cx * maxCy / cy).round();
            cy = maxCy;
          }
          body.write(_image(rid, imageId, cx, cy));
        case PageBreakBlock():
          body.write('<w:p><w:r><w:br w:type="page"/></w:r></w:p>');
      }
    }

    final document = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
        'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" '
        'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
        'xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">'
        '<w:body>$body'
        '<w:sectPr><w:pgSz w:w="$_pageW" w:h="$_pageH"/>'
        '<w:pgMar w:top="$_margin" w:right="$_margin" w:bottom="$_margin" w:left="$_margin" w:header="709" w:footer="709" w:gutter="0"/>'
        '</w:sectPr></w:body></w:document>';

    final archive = Archive();
    void add(String path, String xml) {
      final bytes = utf8.encode(xml);
      archive.addFile(ArchiveFile(path, bytes.length, bytes));
    }

    add('[Content_Types].xml', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Default Extension="jpeg" ContentType="image/jpeg"/>'
        '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
        '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>'
        '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>'
        '</Types>');
    add('_rels/.rels', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>'
        '</Relationships>');
    add('docProps/core.xml', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>${esc(title)}</dc:title></cp:coreProperties>');
    add('word/_rels/document.xml.rels', '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
        '${rels.join()}</Relationships>');
    add('word/styles.xml', _styles);
    add('word/document.xml', document);
    for (final e in media.entries) {
      archive.addFile(ArchiveFile('word/media/${e.key}', e.value.length, e.value));
    }
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  static String esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      // Control characters are not allowed in XML 1.0.
      .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '');

  static String _p(String text, {String? style, bool firstLineIndent = false}) {
    final ppr = StringBuffer();
    if (style != null) ppr.write('<w:pStyle w:val="$style"/>');
    // Two characters (2 x 10.5 pt) of first-line indent.
    if (firstLineIndent) ppr.write('<w:ind w:firstLineChars="200" w:firstLine="420"/>');
    return '<w:p>${ppr.isEmpty ? '' : '<w:pPr>$ppr</w:pPr>'}'
        '<w:r><w:t xml:space="preserve">${esc(text)}</w:t></w:r></w:p>';
  }

  static String _table(TableGrid g, double widthFraction) {
    if (g.rows < 1 || g.cols < 1) return '';
    final total = (_textWidthTwips * widthFraction.clamp(0.3, 1.0)).round();
    final colW = (total / g.cols).floor();
    final starts = <(int, int), TableCell>{for (final c in g.cells) (c.row, c.col): c};
    // Cells continuing a rowspan: (row, col) -> the cell that started it.
    final continued = <(int, int), TableCell>{};
    for (final c in g.cells) {
      for (var r = c.row + 1; r < c.row + c.rowSpan; r++) {
        continued[(r, c.col)] = c;
      }
    }
    final sb = StringBuffer('<w:tbl><w:tblPr><w:tblStyle w:val="TableGrid"/><w:tblW w:w="$total" w:type="dxa"/>'
        '<w:tblLayout w:type="fixed"/></w:tblPr><w:tblGrid>');
    for (var c = 0; c < g.cols; c++) {
      sb.write('<w:gridCol w:w="$colW"/>');
    }
    sb.write('</w:tblGrid>');
    for (var r = 0; r < g.rows; r++) {
      sb.write('<w:tr>');
      var c = 0;
      while (c < g.cols) {
        final start = starts[(r, c)];
        final cont = continued[(r, c)];
        final span = ((start ?? cont)?.colSpan ?? 1).clamp(1, g.cols - c);
        final w = colW * span;
        sb.write('<w:tc><w:tcPr><w:tcW w:w="$w" w:type="dxa"/>');
        if (span > 1) sb.write('<w:gridSpan w:val="$span"/>');
        if (start != null && start.rowSpan > 1) sb.write('<w:vMerge w:val="restart"/>');
        if (start == null && cont != null) sb.write('<w:vMerge/>');
        sb.write('</w:tcPr>');
        sb.write(start == null ? '<w:p/>' : _p(start.text));
        sb.write('</w:tc>');
        c += span;
      }
      sb.write('</w:tr>');
    }
    sb.write('</w:tbl>');
    return sb.toString();
  }

  static String _image(String rid, int id, int cx, int cy) => '<w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:drawing>'
      '<wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="$cx" cy="$cy"/>'
      '<wp:docPr id="$id" name="图片 $id"/>'
      '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">'
      '<pic:pic><pic:nvPicPr><pic:cNvPr id="$id" name="image$id.jpeg"/><pic:cNvPicPr/></pic:nvPicPr>'
      '<pic:blipFill><a:blip r:embed="$rid"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>'
      '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="$cx" cy="$cy"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>'
      '</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>';

  /// 宋体 / Times New Roman body at 10.5 pt (五号), 黑体 headings.
  static const _styles = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:docDefaults><w:rPrDefault><w:rPr>'
      '<w:rFonts w:ascii="Times New Roman" w:hAnsi="Times New Roman" w:eastAsia="宋体" w:cs="Times New Roman"/>'
      '<w:sz w:val="21"/><w:szCs w:val="21"/><w:lang w:val="en-US" w:eastAsia="zh-CN"/></w:rPr></w:rPrDefault>'
      '<w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="300" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>'
      '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>'
      '<w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>'
      '<w:pPr><w:keepNext/><w:spacing w:before="240" w:after="240"/><w:jc w:val="center"/><w:outlineLvl w:val="0"/></w:pPr>'
      '<w:rPr><w:rFonts w:eastAsia="黑体"/><w:b/><w:sz w:val="36"/><w:szCs w:val="36"/></w:rPr></w:style>'
      '<w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>'
      '<w:pPr><w:keepNext/><w:spacing w:before="200" w:after="120"/><w:outlineLvl w:val="1"/></w:pPr>'
      '<w:rPr><w:rFonts w:eastAsia="黑体"/><w:b/><w:sz w:val="28"/><w:szCs w:val="28"/></w:rPr></w:style>'
      '<w:style w:type="paragraph" w:styleId="Caption"><w:name w:val="caption"/><w:basedOn w:val="Normal"/><w:qFormat/>'
      '<w:pPr><w:jc w:val="center"/></w:pPr><w:rPr><w:sz w:val="18"/><w:szCs w:val="18"/></w:rPr></w:style>'
      '<w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/><w:tblPr><w:tblBorders>'
      '<w:top w:val="single" w:sz="4" w:space="0" w:color="000000"/><w:left w:val="single" w:sz="4" w:space="0" w:color="000000"/>'
      '<w:bottom w:val="single" w:sz="4" w:space="0" w:color="000000"/><w:right w:val="single" w:sz="4" w:space="0" w:color="000000"/>'
      '<w:insideH w:val="single" w:sz="4" w:space="0" w:color="000000"/><w:insideV w:val="single" w:sz="4" w:space="0" w:color="000000"/>'
      '</w:tblBorders></w:tblPr></w:style>'
      '</w:styles>';
}
