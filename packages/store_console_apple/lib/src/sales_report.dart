import 'dart:convert';
import 'dart:io';

import 'package:store_console/store_console.dart';

/// Apple's product type identifiers for a first-time download of an app.
/// Updates (7…), re-downloads (3…), bundles and in-app purchases are left out.
const firstTimeDownloadTypes = {'1', '1F', '1T', 'F1', '1E', '1EP', '1EU'};

/// The text of a sales report as Apple sends it: a gzip file.
String decodeSalesReport(List<int> bytes) {
  final gzipped = bytes.length > 2 && bytes[0] == 0x1f && bytes[1] == 0x8b;
  try {
    return utf8.decode(gzipped ? gzip.decode(bytes) : bytes);
  } on FormatException {
    throw _unreadable;
  }
}

/// First-time download units in one Summary Sales Report, by Apple
/// identifier. Refunds count against the day they are reported on.
Map<String, int> parseSalesUnits(String tsv) {
  final lines = const LineSplitter()
      .convert(tsv)
      .where((line) => line.trim().isNotEmpty)
      .toList();
  if (lines.isEmpty) return const {};

  final header = [for (final cell in lines.first.split('\t')) cell.trim()];
  final typeAt = header.indexOf('Product Type Identifier');
  final unitsAt = header.indexOf('Units');
  final appAt = header.indexOf('Apple Identifier');
  if (typeAt < 0 || unitsAt < 0 || appAt < 0) throw _unreadable;
  final widest = [typeAt, unitsAt, appAt].reduce((a, b) => a > b ? a : b);

  final units = <String, int>{};
  for (final line in lines.skip(1)) {
    final cells = line.split('\t');
    if (cells.length <= widest) continue;
    if (!firstTimeDownloadTypes.contains(cells[typeAt].trim())) continue;
    final count = num.tryParse(cells[unitsAt].trim());
    if (count == null) continue;
    final app = cells[appAt].trim();
    units[app] = (units[app] ?? 0) + count.round();
  }
  return units;
}

const _unreadable = StoreException(
  StoreFailure.shape,
  'The App Store sent a sales report in a form this version does not read.',
);
