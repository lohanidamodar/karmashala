import 'package:store_console/store_console.dart';
import 'package:store_console_play/src/play_icon.dart';
import 'package:store_console_play/src/play_installs.dart';
import 'package:store_console_play/src/report_csv.dart';
import 'package:test/test.dart';

const _withTotal =
    'Date,Package Name,Daily Device Installs,Total User Installs,'
    'Daily User Installs\n'
    '2026-09-01,com.example.app,7,500,5\n'
    '2026-09-03,com.example.app,11,514,8\n'
    '2026-09-02,com.example.app,9,506,6\n';

const _dailyOnly =
    'Date,Package Name,Daily Device Installs,Daily User Installs\n'
    '2026-08-30,com.example.app,4,3\n'
    '2026-08-31,com.example.app,NA,2\n';

const _deviceOnly =
    'Date,Package Name,Daily Device Installs\n'
    '2024-03-01,com.example.app,10\n';

void main() {
  group('summariseInstalls', () {
    test('sums the daily columns and keeps the newest lifetime count', () {
      final month = summariseInstalls(ReportTable.parse(_withTotal));
      expect(month.userInstalls, 19);
      expect(month.deviceInstalls, 27);
      expect(month.totalUsers, 514);
      expect(month.totalUsersDay, DateTime.utc(2026, 9, 3));
      expect(month.lastDay, DateTime.utc(2026, 9, 3));
    });

    test('a column the file lacks is null, not zero', () {
      final month = summariseInstalls(ReportTable.parse(_deviceOnly));
      expect(month.userInstalls, isNull);
      expect(month.deviceInstalls, 10);
      expect(month.totalUsers, isNull);
    });

    test('survives JSON', () {
      final month = summariseInstalls(ReportTable.parse(_dailyOnly));
      final back = MonthInstalls.fromJson(month.toJson());
      expect(back.userInstalls, 5);
      expect(back.deviceInstalls, 4);
      expect(back.lastDay, DateTime.utc(2026, 8, 31));
    });

    test('a file with no Date column is a shape failure', () {
      expect(
        () => summariseInstalls(ReportTable.parse('Other\n1\n')),
        throwsA(
          isA<StoreException>().having(
            (e) => e.kind,
            'kind',
            StoreFailure.shape,
          ),
        ),
      );
    });
  });

  test('installsMonthOf reads only this package\'s overviews', () {
    expect(
      installsMonthOf(
        'stats/installs/installs_com.example.app_202403_overview.csv',
        'com.example.app',
      ),
      DateTime.utc(2024, 3),
    );
    expect(
      installsMonthOf(
        'stats/installs/installs_com.example.app_pro_202403_overview.csv',
        'com.example.app',
      ),
      isNull,
    );
    expect(
      installsMonthOf(
        'stats/installs/installs_com.example.app_202403_country.csv',
        'com.example.app',
      ),
      isNull,
    );
  });

  group('allTimeFromMonths', () {
    test('Play\'s own lifetime count wins when the newest month has one', () {
      final total = allTimeFromMonths([
        (
          DateTime.utc(2026, 8),
          summariseInstalls(ReportTable.parse(_dailyOnly)),
        ),
        (
          DateTime.utc(2026, 9),
          summariseInstalls(ReportTable.parse(_withTotal)),
        ),
      ]);
      expect(total.count, 514);
      expect(total.measure, 'user installs');
      expect(total.since, isNull);
      expect(total.through, DateTime.utc(2026, 9, 3));
    });

    test('else every month\'s daily user installs are added up', () {
      final total = allTimeFromMonths([
        (
          DateTime.utc(2026, 7),
          summariseInstalls(ReportTable.parse(_dailyOnly)),
        ),
        (
          DateTime.utc(2026, 8),
          summariseInstalls(ReportTable.parse(_dailyOnly)),
        ),
      ]);
      expect(total.count, 10);
      expect(total.measure, 'user installs');
      expect(total.since, '2026-07');
      expect(total.through, DateTime.utc(2026, 8, 31));
      expect(total.atLeast, isFalse);
    });

    test('a month without a user column counts its device installs', () {
      final total = allTimeFromMonths([
        (
          DateTime.utc(2024, 3),
          summariseInstalls(ReportTable.parse(_deviceOnly)),
        ),
        (
          DateTime.utc(2026, 8),
          summariseInstalls(ReportTable.parse(_dailyOnly)),
        ),
      ]);
      expect(total.count, 15);
      expect(total.measure, 'installs');
      expect(total.since, '2024-03');
    });

    test('no months is said, not zero', () {
      expect(
        () => allTimeFromMonths(const []),
        throwsA(
          isA<StoreException>().having(
            (e) => e.kind,
            'kind',
            StoreFailure.notSupported,
          ),
        ),
      );
    });
  });

  group('PlayInstallMonths', () {
    const bucket = 'pubsite_prod_rev_1';
    const object =
        'stats/installs/installs_com.example.app_202608_overview.csv';
    const other = 'stats/installs/installs_com.example.app_202607_overview.csv';
    final summary = summariseInstalls(ReportTable.parse(_dailyOnly));

    test('a month is held at the generation it was read at', () {
      final months = PlayInstallMonths()..keep(bucket, object, '7', summary);
      expect(months.at(bucket, object, '7'), isNotNull);
      expect(months.at(bucket, object, '8'), isNull);
      expect(months.at('another', object, '7'), isNull);
    });

    test('survives JSON, and drops files no longer listed', () {
      final months = PlayInstallMonths()
        ..keep(bucket, object, '7', summary)
        ..keep(bucket, other, '3', summary);
      final back = PlayInstallMonths.fromJson(months.toJson());
      expect(back.at(bucket, object, '7')!.userInstalls, 5);
      back.keepOnly(bucket, 'stats/installs/installs_com.example.app_', {
        object,
      });
      expect(back.at(bucket, other, '3'), isNull);
      expect(back.at(bucket, object, '7'), isNotNull);
    });
  });

  group('playInstallBand', () {
    test('reads the figure before "Downloads"', () {
      const html =
          '<div class="w7Iutd"><div class="wVqUob"><div class="ClM7O">4.5'
          '</div></div><div class="wVqUob"><div class="ClM7O">10K+</div>'
          '<div class="g1rdde">Downloads</div></div></div>';
      expect(playInstallBand(html), '10K+');
    });

    test('falls back to the short form in the page data', () {
      const html = '<script>x=[["100,000+",100000,123456,"100K+"]]</script>';
      expect(playInstallBand(html), '100K+');
    });

    test('says nothing for a page it does not read', () {
      expect(playInstallBand('<div>Téléchargements</div>'), isNull);
      expect(
        playInstallBand('<div>Mature 17+</div><div>Downloads</div>'),
        isNull,
      );
    });
  });
}
