import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:store_console/store_console.dart';
import 'package:store_console_play/src/play_reporting.dart';
import 'package:test/test.dart';

Map<String, Object?> row(int day, Map<String, String> metrics) => {
  'aggregationPeriod': 'DAILY',
  'startTime': {
    'year': 2026,
    'month': 9,
    'day': day,
    'timeZone': {'id': 'America/Los_Angeles'},
  },
  'metrics': [
    for (final MapEntry(:key, :value) in metrics.entries)
      {
        'metric': key,
        'decimalValue': {'value': value},
      },
  ],
};

http.Response json(Object? body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  group('parseVitalsRate', () {
    test('takes the newest 28-day user-weighted figure', () {
      final rate = parseVitalsRate({
        'rows': [
          row(27, {'userPerceivedCrashRate28dUserWeighted': '0.012'}),
          row(26, {'userPerceivedCrashRate28dUserWeighted': '0.5'}),
        ],
      }, VitalsMetric.crash);
      expect(rate, 0.012);
    });

    test('else weights the daily rate by its users', () {
      final rate = parseVitalsRate({
        'rows': [
          row(1, {'userPerceivedAnrRate': '0.01', 'distinctUsers': '100'}),
          row(2, {'userPerceivedAnrRate': '0.04', 'distinctUsers': '300'}),
          row(3, {'distinctUsers': '900'}),
        ],
      }, VitalsMetric.anr);
      expect(rate, closeTo(0.0325, 1e-12));
    });

    test('averages plainly when no day says its users', () {
      final rate = parseVitalsRate({
        'rows': [
          row(1, {'userPerceivedAnrRate': '0.01'}),
          row(2, {'userPerceivedAnrRate': '0.03'}),
        ],
      }, VitalsMetric.anr);
      expect(rate, closeTo(0.02, 1e-12));
    });

    test('is null with no rows, or none with the metric', () {
      expect(parseVitalsRate(const {}, VitalsMetric.crash), isNull);
      expect(
        parseVitalsRate({
          'rows': [
            row(1, {'distinctUsers': '5'}),
          ],
        }, VitalsMetric.crash),
        isNull,
      );
    });

    test('reads metrics keyed by name as well', () {
      final rate = parseVitalsRate({
        'rows': [
          {
            'startTime': {'year': 2026, 'month': 9, 'day': 1},
            'metrics': {
              'userPerceivedCrashRate28dUserWeighted': {'decimalValue': '0.02'},
            },
          },
        ],
      }, VitalsMetric.crash);
      expect(rate, 0.02);
    });
  });

  test('parseDailyFreshness reads the DAILY end day', () {
    expect(
      parseDailyFreshness({
        'name': 'apps/com.example.app/crashRateMetricSet',
        'freshnessInfo': {
          'freshnesses': [
            {
              'aggregationPeriod': 'HOURLY',
              'latestEndTime': {'year': 2026, 'month': 9, 'day': 30},
            },
            {
              'aggregationPeriod': 'DAILY',
              'latestEndTime': {
                'year': 2026,
                'month': 9,
                'day': 28,
                'timeZone': {'id': 'America/Los_Angeles'},
              },
            },
          ],
        },
      }),
      DateTime.utc(2026, 9, 28),
    );
    expect(parseDailyFreshness(const {}), isNull);
  });

  test('vitalsQuery asks for days in Los Angeles time', () {
    final query = vitalsQuery(
      VitalsMetric.anr,
      start: DateTime.utc(2026, 8, 31),
      end: DateTime.utc(2026, 9, 28),
    );
    expect(query['metrics'], [
      'userPerceivedAnrRate28dUserWeighted',
      'userPerceivedAnrRate',
      'distinctUsers',
    ]);
    expect(query['timelineSpec'], {
      'aggregationPeriod': 'DAILY',
      'startTime': {
        'year': 2026,
        'month': 8,
        'day': 31,
        'timeZone': {'id': 'America/Los_Angeles'},
      },
      'endTime': {
        'year': 2026,
        'month': 9,
        'day': 28,
        'timeZone': {'id': 'America/Los_Angeles'},
      },
    });
  });

  test('parseReportingApps keeps the package and a real display name', () {
    expect(
      parseReportingApps({
        'apps': [
          {'name': 'apps/a', 'packageName': 'com.a', 'displayName': 'Alpha'},
          {'name': 'apps/b', 'packageName': 'com.b', 'displayName': ' '},
          {'name': 'apps/c'},
        ],
      }),
      [
        (packageName: 'com.a', displayName: 'Alpha'),
        (packageName: 'com.b', displayName: null),
      ],
    );
  });

  group('PlayReporting', () {
    test('searchApps follows the page token', () async {
      final seen = <Uri>[];
      final reporting = PlayReporting(
        MockClient((request) async {
          seen.add(request.url);
          return request.url.queryParameters['pageToken'] == null
              ? json({
                  'apps': [
                    {'packageName': 'com.a', 'displayName': 'Alpha'},
                  ],
                  'nextPageToken': 'next',
                })
              : json({
                  'apps': [
                    {'packageName': 'com.b'},
                  ],
                });
        }),
      );

      final apps = await reporting.searchApps();

      expect([for (final app in apps) app.packageName], ['com.a', 'com.b']);
      expect(seen, hasLength(2));
      expect(seen.first.path, '/v1beta1/apps:search');
      expect(seen.last.queryParameters['pageToken'], 'next');
    });

    test('rate posts the query to the metric set', () async {
      late http.Request sent;
      final reporting = PlayReporting(
        MockClient((request) async {
          sent = request;
          return json({
            'rows': [
              row(27, {'userPerceivedCrashRate28dUserWeighted': '0.007'}),
            ],
          });
        }),
      );

      final rate = await reporting.rate(
        'com.example.app',
        VitalsMetric.crash,
        start: DateTime.utc(2026, 8, 31),
        end: DateTime.utc(2026, 9, 28),
      );

      expect(rate, 0.007);
      expect(sent.method, 'POST');
      expect(
        sent.url.toString(),
        'https://playdeveloperreporting.googleapis.com/v1beta1/apps/'
        'com.example.app/crashRateMetricSet:query',
      );
      final body = (jsonDecode(sent.body) as Map).cast<String, Object?>();
      expect(
        body,
        vitalsQuery(
          VitalsMetric.crash,
          start: DateTime.utc(2026, 8, 31),
          end: DateTime.utc(2026, 9, 28),
        ),
      );
    });

    test('a refusal is a permission failure', () async {
      final reporting = PlayReporting(
        MockClient((_) async => json({'error': 'secret detail'}, 403)),
      );
      await expectLater(
        reporting.dailyFreshness('com.example.app', VitalsMetric.anr),
        throwsA(
          isA<StoreException>()
              .having((e) => e.kind, 'kind', StoreFailure.permission)
              .having((e) => e.message, 'message', isNot(contains('secret'))),
        ),
      );
    });

    test('a body that is not JSON is a shape failure', () async {
      final reporting = PlayReporting(
        MockClient((_) async => http.Response('<html>', 200)),
      );
      await expectLater(
        reporting.searchApps(),
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
}
