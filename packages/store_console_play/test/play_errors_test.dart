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

StoreFailure kindOf(Object error, {PlayArea area = PlayArea.console}) =>
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
      expect(bucket.message, contains('reports'));
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

    test('typed packages are listed when the key cannot search', () async {
      final play = client(
        const PlayAccount(
          serviceAccountJson: '{}',
          packageNames: ['com.zeta', ' com.alpha ', ''],
        ),
      );
      final apps = await play.listApps();
      expect([for (final app in apps) app.id], ['com.alpha', 'com.zeta']);
      expect(apps.first.name, 'com.alpha');
      expect(apps.first.store, StoreKind.googlePlay);
      play.close();
    });
  });
}
