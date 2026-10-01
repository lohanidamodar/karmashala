import 'dart:convert';

/// The text of a Play Console report. They are UTF-16 with a byte-order
/// mark; a file without one is taken as UTF-16 when its bytes look it.
String decodeReport(List<int> bytes) {
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return _utf16(bytes, 2, littleEndian: true);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    return _utf16(bytes, 2, littleEndian: false);
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    return utf8.decode(bytes.sublist(3), allowMalformed: true);
  }
  if (bytes.length >= 2 && bytes[1] == 0 && bytes[0] != 0) {
    return _utf16(bytes, 0, littleEndian: true);
  }
  if (bytes.length >= 2 && bytes[0] == 0 && bytes[1] != 0) {
    return _utf16(bytes, 0, littleEndian: false);
  }
  return utf8.decode(bytes, allowMalformed: true);
}

String _utf16(List<int> bytes, int start, {required bool littleEndian}) {
  final units = <int>[];
  for (var i = start; i + 1 < bytes.length; i += 2) {
    units.add(
      littleEndian
          ? bytes[i] | (bytes[i + 1] << 8)
          : (bytes[i] << 8) | bytes[i + 1],
    );
  }
  return String.fromCharCodes(units);
}

/// Rows of fields, with quoted fields, doubled quotes and line breaks inside
/// quotes read as CSV means them. Blank lines are dropped.
List<List<String>> parseCsv(String text) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var quoted = false;
  var wasQuoted = false;

  void endField() {
    row.add(field.toString());
    field.clear();
    wasQuoted = false;
  }

  void endRow() {
    final blank = row.isEmpty && field.isEmpty && !wasQuoted;
    endField();
    if (!blank) rows.add(row);
    row = <String>[];
  }

  for (var i = 0; i < text.length; i++) {
    final char = text[i];
    if (quoted) {
      if (char != '"') {
        field.write(char);
      } else if (i + 1 < text.length && text[i + 1] == '"') {
        field.write('"');
        i++;
      } else {
        quoted = false;
      }
    } else if (char == '"') {
      quoted = true;
      wasQuoted = true;
    } else if (char == ',') {
      endField();
    } else if (char == '\n') {
      endRow();
    } else if (char != '\r') {
      field.write(char);
    }
  }
  if (row.isNotEmpty || field.isNotEmpty || wasQuoted) endRow();
  return rows;
}

/// A report read by column name, since Play adds columns over time.
class ReportTable {
  const ReportTable(this.headers, this.rows);

  factory ReportTable.parse(String text) {
    final all = parseCsv(text);
    if (all.isEmpty) return const ReportTable([], []);
    return ReportTable(all.first, all.sublist(1));
  }

  factory ReportTable.decode(List<int> bytes) =>
      ReportTable.parse(decodeReport(bytes));

  final List<String> headers;
  final List<List<String>> rows;

  /// The index of the first of [names] the report has, or null.
  int? column(List<String> names) {
    final known = [for (final header in headers) header.trim().toLowerCase()];
    for (final name in names) {
      final index = known.indexOf(name.toLowerCase());
      if (index >= 0) return index;
    }
    return null;
  }

  /// The field at [index], or null on a short row.
  static String? cell(List<String> row, int index) =>
      index < row.length ? row[index].trim() : null;
}
