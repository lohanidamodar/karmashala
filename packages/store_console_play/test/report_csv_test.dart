import 'dart:convert';

import 'package:store_console/store_console.dart';
import 'package:store_console_play/src/play_reports_bucket.dart';
import 'package:store_console_play/src/report_csv.dart';
import 'package:test/test.dart';

List<int> utf16le(String text, {bool bom = true}) => [
  if (bom) ...[0xFF, 0xFE],
  for (final unit in text.codeUnits) ...[unit & 0xFF, unit >> 8],
];

List<int> utf16be(String text) => [
  0xFE,
  0xFF,
  for (final unit in text.codeUnits) ...[unit >> 8, unit & 0xFF],
];

const ratings =
    'Date,Package Name,Daily Average Rating,Total Average Rating\n'
    '2026-09-01,com.example.app,NA,4.31\n'
    '2026-09-03,com.example.app,5.00,4.35\n'
    '2026-09-02,com.example.app,4.00,4.32\n'
    '2026-09-04,com.example.app,NA,NA\n';

const installs =
    'Date,Package Name,Current Device Installs,Daily Device Installs,'
    'Daily Device Uninstalls,Daily Device Upgrades,Current User Installs,'
    'Total User Installs,Daily User Installs,Daily User Uninstalls\r\n'
    '2026-09-01,com.example.app,100,7,1,0,90,500,5,1\r\n'
    '2026-09-02,com.example.app,104,9,2,0,93,506,6,2\r\n'
    '2026-09-03,com.example.app,110,11,0,0,99,514,8,0\r\n';

void main() {
  group('decodeReport', () {
    test('reads UTF-16 LE with a byte-order mark', () {
      expect(decodeReport(utf16le('Date,Ünïcode\n')), 'Date,Ünïcode\n');
    });

    test('reads UTF-16 BE with a byte-order mark', () {
      expect(decodeReport(utf16be('a,b')), 'a,b');
    });

    test('reads UTF-16 LE that lost its mark', () {
      expect(decodeReport(utf16le('Date,x', bom: false)), 'Date,x');
    });

    test('reads UTF-8, with and without a mark', () {
      expect(decodeReport(utf8.encode('a,é')), 'a,é');
      expect(decodeReport([0xEF, 0xBB, 0xBF, ...utf8.encode('a,b')]), 'a,b');
    });

    test('reads nothing as nothing', () {
      expect(decodeReport(const []), '');
    });
  });

  group('parseCsv', () {
    test('splits rows and fields, dropping blank lines', () {
      expect(parseCsv('a,b\r\n\r\n1,2\n'), [
        ['a', 'b'],
        ['1', '2'],
      ]);
    });

    test('keeps commas, quotes and line breaks inside quoted fields', () {
      expect(parseCsv('"a,b","say ""hi""","two\nlines"\nx,,'), [
        ['a,b', 'say "hi"', 'two\nlines'],
        ['x', '', ''],
      ]);
    });

    test('keeps a row that is one empty quoted field', () {
      expect(parseCsv('""\n'), [
        [''],
      ]);
    });
  });

  group('ReportTable', () {
    test('finds a column whatever its case, and the first of several', () {
      final table = ReportTable.parse('Date, Daily Device Installs \n');
      expect(table.column(const ['date']), 0);
      expect(
        table.column(const ['Daily User Installs', 'Daily Device Installs']),
        1,
      );
      expect(table.column(const ['Nope']), isNull);
    });

    test('an empty file has no headers and no rows', () {
      final table = ReportTable.decode(const []);
      expect(table.headers, isEmpty);
      expect(table.rows, isEmpty);
    });
  });

  group('latestAverageRating', () {
    test('takes the newest row that has a number', () {
      final table = ReportTable.decode(utf16le(ratings));
      expect(latestAverageRating(table), 4.35);
    });

    test('is null when no row has a number', () {
      final table = ReportTable.parse(
        'Date,Package Name,Daily Average Rating,Total Average Rating\n'
        '2026-09-01,com.example.app,NA,NA\n',
      );
      expect(latestAverageRating(table), isNull);
    });

    test('refuses a report without the column', () {
      expect(
        () => latestAverageRating(ReportTable.parse('Date,Other\n')),
        throwsA(
          isA<StoreException>().having(
            (error) => error.kind,
            'kind',
            StoreFailure.shape,
          ),
        ),
      );
    });
  });

  group('dailyInstalls', () {
    test('reads user installs inside the window', () {
      final days = dailyInstalls(
        ReportTable.decode(utf16le(installs)),
        from: DateTime.utc(2026, 9, 2),
        to: DateTime.utc(2026, 9, 30),
      );
      expect(days, {DateTime.utc(2026, 9, 2): 6, DateTime.utc(2026, 9, 3): 8});
    });

    test('falls back to device installs', () {
      final days = dailyInstalls(
        ReportTable.parse(
          'Date,Package Name,Daily Device Installs\n'
          '2026-09-02,com.example.app,9\n',
        ),
        from: DateTime.utc(2026, 9),
        to: DateTime.utc(2026, 9, 30),
      );
      expect(days, {DateTime.utc(2026, 9, 2): 9});
    });

    test('refuses a report without an installs column', () {
      expect(
        () => dailyInstalls(
          ReportTable.parse('Date,Package Name\n'),
          from: DateTime.utc(2026, 9),
          to: DateTime.utc(2026, 9, 30),
        ),
        throwsA(isA<StoreException>()),
      );
    });
  });

  group('bucket', () {
    test('normalises what was typed', () {
      expect(
        normaliseBucket('gs://pubsite_prod_rev_123/'),
        'pubsite_prod_rev_123',
      );
      expect(
        normaliseBucket(' GS://pubsite_prod_rev_123/stats/installs '),
        'pubsite_prod_rev_123',
      );
      expect(normaliseBucket('pubsite_prod_rev_123'), 'pubsite_prod_rev_123');
      expect(normaliseBucket('pubsite_prod_123'), 'pubsite_prod_123');
      expect(normaliseBucket('123'), 'pubsite_prod_rev_123');
      expect(normaliseBucket('  '), isNull);
      expect(normaliseBucket(null), isNull);
    });

    test('names the monthly objects', () {
      expect(
        ratingsObject('com.example.app', DateTime.utc(2026, 9, 30)),
        'stats/ratings/ratings_com.example.app_202609_overview.csv',
      );
      expect(
        installsObject('com.example.app', DateTime.utc(2026, 1, 5)),
        'stats/installs/installs_com.example.app_202601_overview.csv',
      );
    });

    test('steps back a month across the year', () {
      expect(previousMonth(DateTime.utc(2026, 1, 31)), DateTime.utc(2025, 12));
      expect(previousMonth(DateTime.utc(2026, 3, 31)), DateTime.utc(2026, 2));
    });
  });
}
