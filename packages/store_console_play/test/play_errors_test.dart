import 'dart:async';
import 'dart:io';

import 'package:googleapis/androidpublisher/v3.dart'
    show ApiRequestError, DetailedApiRequestError;
import 'package:googleapis_auth/googleapis_auth.dart'
    show AccessDeniedException, ServerRequestFailedException;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:store_console/store_console.dart';
import 'package:store_console_play/store_console_play.dart';
import 'package:store_console_play/src/play_errors.dart';
import 'package:test/test.dart';

StoreFailure kindOf(Object error, {PlayArea area = PlayArea.publisher}) =>
    playFailure(error, area: area).kind;

void main() {
  group('playFailure', () {
    test('maps an API status', () {
      StoreFailure status(int code) =>
          kindOf(DetailedApiRequestError(code, 'token=abc'));
      expect(status(401), StoreFailure.auth);
      expect(status(403), StoreFailure.permission);
      expect(status(404), StoreFailure.notConfigured);
      expect(status(429), StoreFailure.rateLimited);
      expect(status(500), StoreFailure.server);
      expect(status(503), StoreFailure.server);
      expect(status(400), StoreFailure.shape);
    });

    test('never repeats the text of what failed', () {
      final failures = [
        playFailure(DetailedApiRequestError(403, 'PRIVATE KEY abc')),
        playFailure(AccessDeniedException('PRIVATE KEY abc')),
        playFailure(const FormatException('PRIVATE KEY abc')),
        playFailure(http.ClientException('PRIVATE KEY abc')),
      ];
      for (final failure in failures) {
        expect(failure.message, isNot(contains('PRIVATE KEY')));
      }
    });

    test('a refusal names the grant for where it happened', () {
      final console = playFailure(DetailedApiRequestError(403, null));
      final bucket = playFailure(
        DetailedApiRequestError(403, null),
        area: PlayArea.bucket,
      );
      expect(console.message, contains('Users and permissions'));
      expect(console.message, contains('access to the app'));
      // With no reason given, the refusal names the API that refused.
      expect(bucket.message, contains(PlayArea.bucket.api));
      // A permission refusal names the grant: the bucket's is the reports.
      final denied = playFailure(
        DetailedApiRequestError(
          403,
          null,
          jsonResponse: {
            'error': {'status': 'PERMISSION_DENIED'},
          },
        ),
        area: PlayArea.bucket,
      );
      expect(denied.message, contains('reports'));
    });

    DetailedApiRequestError refused(Map<String, Object?> error) =>
        DetailedApiRequestError(
          403,
          'PRIVATE KEY abc',
          jsonResponse: {'error': error},
        );

    test('a disabled API is named, with its project', () {
      final failure = playFailure(
        refused({
          'code': 403,
          'message': 'PRIVATE KEY abc',
          'status': 'PERMISSION_DENIED',
          'details': [
            {
              '@type': 'type.googleapis.com/google.rpc.ErrorInfo',
              'reason': 'SERVICE_DISABLED',
              'domain': 'googleapis.com',
              'metadata': {
                'service': 'playdeveloperreporting.googleapis.com',
                'consumer': 'projects/123456',
              },
            },
          ],
        }),
        area: PlayArea.reporting,
      );
      expect(failure.kind, StoreFailure.permission);
      expect(
        failure.message,
        allOf(
          contains('Google Play Developer Reporting API is not enabled'),
          contains('project 123456'),
          contains('APIs & Services'),
          contains('SERVICE_DISABLED'),
          isNot(contains('PRIVATE KEY')),
        ),
      );
    });

    test('a refused permission names the grant for the API', () {
      final denied = {
        'status': 'PERMISSION_DENIED',
        'errors': [
          {'reason': 'permissionDenied', 'message': 'PRIVATE KEY abc'},
        ],
      };
      final reporting = playFailure(refused(denied), area: PlayArea.reporting);
      final reviews = playFailure(refused(denied), area: PlayArea.reviews);
      expect(reporting.message, contains('Reporting API'));
      expect(reporting.message, contains('download bulk reports'));
      expect(reviews.message, contains('Reply to reviews'));
      expect(reviews.message, contains('Android Developer API'));
    });

    test('a reason code that is not a code is not repeated', () {
      final failure = playFailure(
        refused({
          'status': 'PRIVATE KEY abc',
          'errors': [
            {'reason': 'token=abc def'},
          ],
        }),
      );
      expect(failure.message, isNot(contains('PRIVATE')));
      expect(failure.message, isNot(contains('token')));
      expect(failure.message, contains('Users and permissions'));
    });

    test('token failures are auth, unless Google itself fell over', () {
      expect(kindOf(AccessDeniedException('denied')), StoreFailure.auth);
      expect(
        kindOf(
          ServerRequestFailedException(
            'bad',
            statusCode: 400,
            responseContent: null,
          ),
        ),
        StoreFailure.auth,
      );
      expect(
        kindOf(
          ServerRequestFailedException(
            'down',
            statusCode: 503,
            responseContent: null,
          ),
        ),
        StoreFailure.server,
      );
    });

    test('transport failures are network', () {
      expect(kindOf(const SocketException('no route')), StoreFailure.network);
      expect(kindOf(const HandshakeException('tls')), StoreFailure.network);
      expect(kindOf(TimeoutException('slow')), StoreFailure.network);
      expect(kindOf(http.ClientException('reset')), StoreFailure.network);
    });

    test('anything else is shape', () {
      expect(kindOf(ApiRequestError('odd')), StoreFailure.shape);
      expect(kindOf(const FormatException('odd')), StoreFailure.shape);
      expect(kindOf(StateError('odd')), StoreFailure.shape);
    });

    test('a StoreException passes through untouched', () {
      const original = StoreException(StoreFailure.notSupported, 'As is.');
      expect(playFailure(original), same(original));
    });
  });

  test('playGuarded turns whatever is thrown into a StoreException', () async {
    await expectLater(
      playGuarded<void>(() async => throw const SocketException('down')),
      throwsA(
        isA<StoreException>().having(
          (e) => e.kind,
          'kind',
          StoreFailure.network,
        ),
      ),
    );
    expect(await playGuarded(() async => 7), 7);
  });

  group('PlayStoreClient', () {
    final app = const StoreApp(
      store: StoreKind.googlePlay,
      id: 'com.example.app',
      bundleId: 'com.example.app',
      name: 'Example',
    );

    PlayStoreClient client(PlayAccount account) => PlayStoreClient(
      account,
      httpClient: MockClient((_) async => fail('No request is expected.')),
      now: () => DateTime.utc(2026, 9, 30),
    );

    test('a key that is not a key is an auth failure', () async {
      final play = client(const PlayAccount(serviceAccountJson: 'not json'));
      await expectLater(
        play.releases(app),
        throwsA(
          isA<StoreException>().having(
            (e) => e.kind,
            'kind',
            StoreFailure.auth,
          ),
        ),
      );
      play.close();
    });

    test('rating and installs ask for the bucket before anything', () async {
      final play = client(
        const PlayAccount(serviceAccountJson: '{}', reportsBucket: ' '),
      );
      await expectLater(
        play.rating(app),
        throwsA(
          isA<StoreException>()
              .having((e) => e.kind, 'kind', StoreFailure.notConfigured)
              .having(
                (e) => e.message,
                'message',
                'Add your reports bucket in Settings → Stores to see the '
                    'rating.',
              ),
        ),
      );
      await expectLater(
        play.downloads(app),
        throwsA(
          isA<StoreException>().having(
            (e) => e.message,
            'message',
            'Add your reports bucket in Settings → Stores to see installs.',
          ),
        ),
      );
      play.close();
    });

    // Typed packages stand in only for a search the account may not make (a
    // permission refusal); a key that cannot be read is said even then.
    test(
      'a key that cannot be read is said though packages were typed',
      () async {
        final play = client(
          const PlayAccount(
            serviceAccountJson: '{}',
            packageNames: ['com.zeta', ' com.alpha ', ''],
          ),
        );
        await expectLater(
          play.listApps(),
          throwsA(
            isA<StoreException>().having(
              (e) => e.kind,
              'kind',
              StoreFailure.auth,
            ),
          ),
        );
        play.close();
      },
    );
  });
}
