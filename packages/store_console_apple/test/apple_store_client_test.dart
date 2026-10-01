import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:store_console/store_console.dart';
import 'package:store_console_apple/store_console_apple.dart';
import 'package:test/test.dart';

import 'support.dart';

AppleStoreClient clientWith(
  MockClientHandler handler, {
  String? vendorNumber,
  DateTime Function()? now,
}) => AppleStoreClient(
  testKey(vendorNumber: vendorNumber),
  httpClient: MockClient(handler),
  now: now ?? () => fixedNow,
);

Map<String, Object?> version(
  String id,
  String state,
  String created, {
  String platform = 'IOS',
  String? phasedId,
  String? buildId,
}) => {
  'type': 'appStoreVersions',
  'id': id,
  'attributes': {
    'versionString': id,
    'appVersionState': state,
    'platform': platform,
    'createdDate': created,
  },
  'relationships': {
    'appStoreVersionPhasedRelease': {
      'data': phasedId == null
          ? null
          : {'type': 'appStoreVersionPhasedReleases', 'id': phasedId},
    },
    'build': {
      'data': buildId == null ? null : {'type': 'builds', 'id': buildId},
    },
  },
};

final versionsDocument = {
  'data': [
    version('1.0', 'REPLACED_WITH_NEW_VERSION', '2026-08-01T10:00:00Z'),
    version('1.3', 'IN_REVIEW', '2026-09-28T10:00:00Z', platform: 'MAC_OS'),
    version(
      '1.2',
      'READY_FOR_DISTRIBUTION',
      '2026-09-20T10:00:00Z',
      phasedId: 'p1',
      buildId: 'b42',
    ),
    version('1.1', 'READY_FOR_DISTRIBUTION', '2026-09-01T10:00:00-07:00'),
  ],
  'included': [
    {
      'type': 'appStoreVersionPhasedReleases',
      'id': 'p1',
      'attributes': {'phasedReleaseState': 'ACTIVE', 'currentDayNumber': 4},
    },
    {
      'type': 'builds',
      'id': 'b42',
      'attributes': {'version': '42'},
    },
  ],
};

final buildsDocument = {
  'data': [
    {
      'type': 'builds',
      'id': 'b50',
      'attributes': {
        'version': '50',
        'uploadedDate': '2026-09-29T08:00:00Z',
        'processingState': 'VALID',
        'expired': false,
      },
      'relationships': {
        'preReleaseVersion': {
          'data': {'type': 'preReleaseVersions', 'id': 'pre1'},
        },
      },
    },
    {
      'type': 'builds',
      'id': 'b30',
      'attributes': {
        'version': '30',
        'uploadedDate': '2026-06-01T08:00:00Z',
        'processingState': 'VALID',
        'expired': true,
      },
    },
  ],
  'included': [
    {
      'type': 'preReleaseVersions',
      'id': 'pre1',
      'attributes': {'version': '1.4'},
    },
  ],
};

void main() {
  test('listApps follows links.next and sends the bearer token', () async {
    final seen = <http.Request>[];
    final client = clientWith((request) async {
      seen.add(request);
      if (request.url.queryParameters['cursor'] == 'two') {
        return jsonResponse({
          'data': [
            {
              'type': 'apps',
              'id': '222',
              'attributes': {'name': 'Second', 'bundleId': 'com.example.two'},
            },
          ],
          'links': {'self': 'https://api.appstoreconnect.apple.com/v1/apps'},
        });
      }
      return jsonResponse({
        'data': [
          {
            'type': 'apps',
            'id': '111',
            'attributes': {'name': 'First', 'bundleId': 'com.example.one'},
          },
        ],
        'links': {
          'next': 'https://api.appstoreconnect.apple.com/v1/apps?cursor=two',
        },
      });
    });

    final apps = await client.listApps();

    expect([for (final app in apps) app.id], ['111', '222']);
    expect(apps.first.store, StoreKind.appStore);
    expect(apps.first.bundleId, 'com.example.one');
    expect(apps.last.name, 'Second');
    expect(seen, hasLength(2));
    expect(seen.first.url.path, '/v1/apps');
    expect(seen.first.url.queryParameters['fields[apps]'], 'name,bundleId');
    expect(seen.first.url.queryParameters['limit'], '200');
    expect(seen.first.headers['Authorization'], startsWith('Bearer '));
  });

  test('releases joins versions and builds, in the dashboard order', () async {
    final client = clientWith((request) async {
      return request.url.path == '/v1/builds'
          ? jsonResponse(buildsDocument)
          : jsonResponse(versionsDocument);
    });

    final releases = await client.releases(testApp);

    expect(
      [for (final release in releases) '${release.track} ${release.version}'],
      [
        'App Store 1.1',
        'App Store (macOS) 1.3',
        'App Store 1.2',
        'App Store 1.0',
        'TestFlight 1.4',
        'TestFlight ',
      ],
    );
    final rolling = releases[2];
    expect(rolling.state, ReleaseState.rollingOut);
    expect(rolling.rawState, 'READY_FOR_DISTRIBUTION');
    expect(rolling.rolloutFraction, 0.10);
    expect(rolling.build, '42');
    expect(releases[0].state, ReleaseState.live);
    expect(releases[0].rolloutFraction, isNull);
    expect(releases[0].date, DateTime.utc(2026, 9, 1, 17));
    expect(releases[4].state, ReleaseState.testing);
    expect(releases[4].build, '50');
    expect(releases[5].state, ReleaseState.superseded);
    expect(releases[5].rawState, 'EXPIRED');
  });

  test('releases survives a key that may not read TestFlight', () async {
    final client = clientWith((request) async {
      return request.url.path == '/v1/builds'
          ? jsonResponse({'errors': <Object>[]}, status: 403)
          : jsonResponse(versionsDocument);
    });

    final releases = await client.releases(testApp);

    expect(releases, hasLength(4));
    expect(releases.every((release) => release.track != 'TestFlight'), isTrue);
  });

  test('reviews carry the included response', () async {
    late Uri asked;
    final client = clientWith((request) async {
      asked = request.url;
      return jsonResponse({
        'data': [
          {
            'type': 'customerReviews',
            'id': 'r1',
            'attributes': {
              'rating': 2,
              'title': 'Crashes',
              'body': 'It crashes on launch.',
              'reviewerNickname': 'someone',
              'createdDate': '2026-09-27T09:30:00Z',
              'territory': 'USA',
            },
            'relationships': {
              'response': {
                'data': {'type': 'customerReviewResponses', 'id': 'resp1'},
              },
            },
          },
          {
            'type': 'customerReviews',
            'id': 'r2',
            'attributes': {
              'rating': 5,
              'title': '',
              'body': 'Great.',
              'createdDate': '2026-09-20T09:30:00Z',
              'territory': 'GBR',
            },
            'relationships': {
              'response': {'data': null},
            },
          },
        ],
        'included': [
          {
            'type': 'customerReviewResponses',
            'id': 'resp1',
            'attributes': {
              'responseBody': 'Fixed in 1.2.',
              'lastModifiedDate': '2026-09-28T12:00:00Z',
              'state': 'PUBLISHED',
            },
          },
        ],
      });
    });

    final reviews = await client.reviews(testApp);

    expect(asked.path, '/v1/apps/${testApp.id}/customerReviews');
    expect(asked.queryParameters, {
      'sort': '-createdDate',
      'limit': '50',
      'include': 'response',
    });
    final answered = reviews.first;
    expect(answered.id, 'r1');
    expect(answered.rating, 2);
    expect(answered.title, 'Crashes');
    expect(answered.body, 'It crashes on launch.');
    expect(answered.author, 'someone');
    expect(answered.locale, 'USA');
    expect(answered.createdAt, DateTime.utc(2026, 9, 27, 9, 30));
    expect(answered.reply, 'Fixed in 1.2.');
    expect(answered.repliedAt, DateTime.utc(2026, 9, 28, 12));
    expect(reviews.last.answered, isFalse);
    expect(reviews.last.title, isNull);
    expect(reviews.last.author, isNull);
  });

  test('rating reads the public lookup without the token', () async {
    late http.Request seen;
    final client = clientWith((request) async {
      seen = request;
      return jsonResponse({
        'resultCount': 1,
        'results': [
          {'averageUserRating': 4.61, 'userRatingCount': 1204},
        ],
      });
    });

    final rating = await client.rating(testApp);

    expect(rating.average, 4.61);
    expect(rating.count, 1204);
    expect(seen.url.host, 'itunes.apple.com');
    expect(seen.url.queryParameters['id'], testApp.id);
    expect(seen.headers.containsKey('Authorization'), isFalse);
  });

  test('an app with no rating yet is not supported, not zero', () async {
    final none = clientWith(
      (_) async => jsonResponse({'resultCount': 0, 'results': <Object>[]}),
    );
    final unrated = clientWith(
      (_) async => jsonResponse({
        'resultCount': 1,
        'results': [
          {'trackName': 'Example'},
        ],
      }),
    );
    expect(none.rating(testApp), storeFailure(StoreFailure.notSupported));
    expect(unrated.rating(testApp), storeFailure(StoreFailure.notSupported));
  });

  test('vitals are never supported, and no request is made', () async {
    var requests = 0;
    final client = clientWith((_) async {
      requests++;
      return jsonResponse({});
    });
    await expectLater(
      client.vitals(testApp),
      storeFailure(StoreFailure.notSupported),
    );
    expect(requests, 0);
  });

  group('downloads', () {
    const header =
        'Provider\tSKU\tProduct Type Identifier\tUnits\tApple Identifier';
    String report(int units) =>
        '$header\nAPPLE\tsku\t1F\t$units\t${testApp.id}\n'
        'APPLE\tsku\t7F\t99\t${testApp.id}\n'
        'APPLE\tother\t1\t7\t999\n';

    test('without a vendor number it is not configured', () async {
      final client = clientWith((_) async => jsonResponse({}));
      await expectLater(
        client.downloads(testApp),
        storeFailure(StoreFailure.notConfigured),
      );
    });

    test('each day is fetched once for every app, oldest first', () async {
      final asked = <String>[];
      final client = clientWith(vendorNumber: '85000000', (request) async {
        final query = request.url.queryParameters;
        expect(request.url.path, '/v1/salesReports');
        expect(query['filter[frequency]'], 'DAILY');
        expect(query['filter[reportType]'], 'SALES');
        expect(query['filter[reportSubType]'], 'SUMMARY');
        expect(query['filter[vendorNumber]'], '85000000');
        final date = query['filter[reportDate]']!;
        asked.add(date);
        if (date == '2026-09-29') {
          return jsonResponse({
            'errors': [
              {'status': '404', 'detail': 'Report is not available yet.'},
            ],
          }, status: 404);
        }
        final day = int.parse(date.substring(8));
        return http.Response.bytes(gzip.encode(utf8.encode(report(day))), 200);
      });

      final first = await client.downloads(testApp);
      final other = await client.downloads(
        const StoreApp(
          store: StoreKind.appStore,
          id: '999',
          bundleId: 'com.example.other',
          name: 'Other',
        ),
      );

      expect(asked, hasLength(14));
      expect(asked.toSet(), hasLength(14));
      expect(first.unit, 'Units');
      expect(first.days, hasLength(13));
      expect(first.days.first.day, DateTime.utc(2026, 9, 16));
      expect(first.days.first.count, 16);
      expect(first.days.last.day, DateTime.utc(2026, 9, 28));
      expect(first.days.last.count, 28);
      expect(other.days.every((day) => day.count == 7), isTrue);
    });

    test('a failed day is asked for again; a fetched day is not', () async {
      var fail = true;
      final asked = <String>[];
      final client = clientWith(vendorNumber: '85000000', (request) async {
        final date = request.url.queryParameters['filter[reportDate]']!;
        asked.add(date);
        if (fail && date == '2026-09-20') return http.Response('', 503);
        return http.Response.bytes(gzip.encode(utf8.encode(report(1))), 200);
      });

      await expectLater(
        client.downloads(testApp),
        storeFailure(StoreFailure.server),
      );
      fail = false;
      final series = await client.downloads(testApp);

      expect(series.days, hasLength(14));
      expect(asked, hasLength(15));
      expect(asked.where((date) => date == '2026-09-20'), hasLength(2));
    });

    test('a 403 names the role sales reports need', () async {
      final client = clientWith(
        vendorNumber: '85000000',
        (_) async => jsonResponse({'errors': <Object>[]}, status: 403),
      );
      await expectLater(
        client.downloads(testApp),
        throwsA(
          isA<StoreException>()
              .having((e) => e.kind, 'kind', StoreFailure.permission)
              .having((e) => e.message, 'message', contains('Finance')),
        ),
      );
    });
  });

  group('errors', () {
    test('401 is an auth failure that does not quote the token', () async {
      String? token;
      final client = clientWith((request) async {
        token = request.headers['Authorization']!.substring('Bearer '.length);
        return jsonResponse({
          'errors': [
            {'status': '401', 'code': 'NOT_AUTHORIZED', 'detail': 'No: $token'},
          ],
        }, status: 401);
      });
      await expectLater(
        client.listApps(),
        throwsA(
          isA<StoreException>()
              .having((e) => e.kind, 'kind', StoreFailure.auth)
              .having((e) => e.message, 'message', isNot(contains(token!))),
        ),
      );
    });

    test('403 is a permission failure with Apple\'s detail', () async {
      final client = clientWith(
        (_) async => jsonResponse({
          'errors': [
            {'status': '403', 'detail': 'This key lacks access.'},
          ],
        }, status: 403),
      );
      await expectLater(
        client.reviews(testApp),
        throwsA(
          isA<StoreException>()
              .having((e) => e.kind, 'kind', StoreFailure.permission)
              .having(
                (e) => e.message,
                'message',
                contains('This key lacks access.'),
              ),
        ),
      );
    });

    test('429 carries retry-after', () async {
      final client = clientWith(
        (_) async => jsonResponse(
          {'errors': <Object>[]},
          status: 429,
          headers: {'retry-after': '120'},
        ),
      );
      await expectLater(
        client.listApps(),
        throwsA(
          isA<StoreException>()
              .having((e) => e.kind, 'kind', StoreFailure.rateLimited)
              .having(
                (e) => e.retryAfter,
                'retryAfter',
                const Duration(minutes: 2),
              ),
        ),
      );
    });

    test('5xx is a server failure', () async {
      final client = clientWith((_) async => http.Response('oops', 502));
      await expectLater(client.listApps(), storeFailure(StoreFailure.server));
    });

    test('a dropped connection is a network failure', () async {
      final client = clientWith(
        (_) async => throw const SocketException('no route'),
      );
      await expectLater(client.listApps(), storeFailure(StoreFailure.network));
    });

    test('a body that is not the expected JSON is a shape failure', () async {
      final notJson = clientWith((_) async => http.Response('<html>', 200));
      final noData = clientWith((_) async => jsonResponse({'items': 1}));
      await expectLater(notJson.listApps(), storeFailure(StoreFailure.shape));
      await expectLater(noData.listApps(), storeFailure(StoreFailure.shape));
    });

    test('a key that cannot sign fails as auth before any request', () async {
      var requests = 0;
      final client = AppleStoreClient(
        const AppleApiKey(keyId: 'K', issuerId: 'I', privateKeyPem: 'nonsense'),
        httpClient: MockClient((_) async {
          requests++;
          return jsonResponse({});
        }),
      );
      await expectLater(client.listApps(), storeFailure(StoreFailure.auth));
      expect(requests, 0);
    });
  });
}
