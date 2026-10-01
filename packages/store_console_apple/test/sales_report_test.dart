import 'dart:convert';
import 'dart:io';

import 'package:store_console/store_console.dart';
import 'package:store_console_apple/src/sales_report.dart';
import 'package:test/test.dart';

import 'support.dart';

const _header =
    'Provider\tProvider Country\tSKU\tDeveloper\tTitle\tVersion\t'
    'Product Type Identifier\tUnits\tDeveloper Proceeds\tBegin Date\t'
    'End Date\tCustomer Currency\tCountry Code\tCurrency of Proceeds\t'
    'Apple Identifier\tCustomer Price';

String _row(String type, String units, String app) =>
    'APPLE\tUS\tsku\tDev\tTitle\t1.0\t$type\t$units\t0\t09/29/2026\t'
    '09/29/2026\tUSD\tUS\tUSD\t$app\t0';

void main() {
  test('first-time downloads are summed by app; the rest is left out', () {
    final units = parseSalesUnits(
      [
        _header,
        _row('1', '3', '111'),
        _row('1F', '4', '111'),
        _row('1T', '2', '111'),
        _row('F1', '5', '222'),
        _row('7', '90', '111'),
        _row('7F', '80', '111'),
        _row('3', '70', '111'),
        _row('3F', '60', '111'),
        _row('IA1', '50', '111'),
        _row('1', '-1', '111'),
        '',
      ].join('\n'),
    );
    expect(units, {'111': 8, '222': 5});
  });

  test('a report with only its header has no units', () {
    expect(parseSalesUnits('$_header\r\n'), isEmpty);
    expect(parseSalesUnits(''), isEmpty);
  });

  test('a report without the expected columns is a shape failure', () {
    expect(
      () => parseSalesUnits('Provider\tUnits\nAPPLE\t1'),
      storeFailure(StoreFailure.shape),
    );
  });

  test('a gzip body is unpacked, and plain text is read as it is', () {
    final text = '$_header\n${_row('1', '3', '111')}';
    expect(decodeSalesReport(gzip.encode(utf8.encode(text))), text);
    expect(decodeSalesReport(utf8.encode(text)), text);
  });
}
