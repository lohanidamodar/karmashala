import 'dart:convert';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/mcp/tools/store_tool_set.dart';
import 'package:karmashala_host/src/stores/store_desk.dart';
import 'package:store_console/store_console.dart';
import 'package:test/test.dart';

/// `store_*`: what the server last read from the stores, for an agent.
void main() {
  final now = DateTime.utc(2026, 10, 1, 12);
  final read = now.subtract(const Duration(minutes: 25));

  const notesIos = StoreApp(
    store: StoreKind.appStore,
    id: '1234567890',
    bundleId: 'com.popupbits.notes',
    name: 'Calm Notes',
  );
  const notesPlay = StoreApp(
    store: StoreKind.googlePlay,
    id: 'com.popupbits.notes',
    bundleId: 'com.popupbits.notes',
    name: 'Calm Notes',
  );
  const liteIos = StoreApp(
    store: StoreKind.appStore,
    id: '2222222222',
    bundleId: 'com.popupbits.noteslite',
    name: 'Calm Notes Lite',
  );
  const tallyPlay = StoreApp(
    store: StoreKind.googlePlay,
    id: 'com.popupbits.tally',
    bundleId: 'com.popupbits.tally',
    name: 'Tally',
  );

  StoreReview review(String id, int rating, int daysAgo, {String? reply}) =>
      StoreReview(
        id: id,
        rating: rating,
        body: 'body $id',
        title: 'title $id',
        author: 'author $id',
        locale: 'en_US',
        appVersion: '2.0.0',
        createdAt: now.subtract(Duration(days: daysAgo)),
        reply: reply,
        repliedAt: reply == null ? null : now,
      );

  final iosSnapshot = StoreAppSnapshot(
    app: notesIos,
    releases: ReadingValue([
      StoreRelease(
        track: 'App Store',
        version: '2.0.0',
        build: '40',
        state: ReleaseState.live,
        rawState: 'READY_FOR_SALE',
        date: DateTime.utc(2026, 9, 20),
      ),
      const StoreRelease(
        track: 'App Store',
        version: '2.1.0',
        build: '41',
        state: ReleaseState.inReview,
        rawState: 'IN_REVIEW',
      ),
    ], read),
    reviews: ReadingValue([
      review('a1', 5, 3),
      review('a2', 2, 1, reply: 'Thanks, fixed in 2.1.'),
    ], read),
    rating: ReadingValue(const RatingSummary(average: 4.567, count: 120), read),
    vitals: ReadingMissing(
      StoreFailure.notSupported,
      'App Store Connect publishes no crash rate through its API.',
      read,
    ),
    downloads: ReadingValue(
      DownloadSeries(
        unit: 'Units',
        days: [
          for (var i = 20; i >= 1; i--)
            DailyCount(DateTime.utc(2026, 9, 30 - i), 1),
        ],
      ),
      read,
    ),
  );

  final playSnapshot = StoreAppSnapshot(
    app: notesPlay,
    releases: ReadingValue(const [
      StoreRelease(
        track: 'production',
        version: '2.0.0',
        build: '40',
        state: ReleaseState.rollingOut,
        rawState: 'inProgress',
        rolloutFraction: 0.2,
      ),
      StoreRelease(
        track: 'beta',
        version: '2.1.0',
        build: '41',
        state: ReleaseState.halted,
        rawState: 'halted',
      ),
    ], read),
    reviews: ReadingValue([review('p1', 1, 0), review('p2', 4, 2)], read),
    rating: ReadingMissing(
      StoreFailure.permission,
      'The service account may not read ratings; grant it View app '
      'information in Play Console.',
      read,
    ),
    vitals: ReadingValue(
      VitalsSummary(
        from: DateTime.utc(2026, 9, 1),
        to: DateTime.utc(2026, 9, 29),
        crashRate: 0.0123,
      ),
      read,
    ),
    downloads: ReadingValue(
      const DownloadSeries(unit: 'Installs', days: []),
      read,
    ),
  );

  final liteSnapshot = StoreAppSnapshot(
    app: liteIos,
    releases: ReadingValue(const [], read),
    reviews: ReadingValue(const [], read),
    rating: ReadingValue(const RatingSummary(average: 4), read),
    vitals: ReadingMissing(StoreFailure.notSupported, 'Not published.', read),
    downloads: ReadingMissing(
      StoreFailure.notConfigured,
      'Add the vendor number in Settings → Stores.',
      read,
    ),
  );

  final apple = AppleKeySummary(
    keyId: 'KEYID12345',
    issuerId: 'issuer-6f1e-secretish',
    vendorNumber: '88776655',
    importedAt: DateTime.utc(2026, 9, 1),
  );
  final play = PlayAccountSummary(
    clientEmail: 'robot@popupbits.iam.gserviceaccount.com',
    reportsBucket: 'pubsite_prod_rev_0123456789',
    packageNames: const ['com.popupbits.notes'],
    importedAt: DateTime.utc(2026, 9, 1),
  );

  StoresView view({
    bool connected = true,
    DateTime? refreshedAt,
    bool neverRead = false,
    Reading<List<StoreApp>>? playApps,
  }) => StoresView(
    apple: connected ? apple : null,
    play: connected ? play : null,
    stores: {
      StoreKind.appStore: ReadingValue([notesIos, liteIos], read),
      StoreKind.googlePlay:
          playApps ?? ReadingValue([notesPlay, tallyPlay], read),
    },
    apps: [iosSnapshot, playSnapshot, liteSnapshot],
    refreshedAt: neverRead ? null : refreshedAt ?? read,
  );

  late _FakeDesk desk;
  late StoreToolSet tools;

  setUp(() {
    desk = _FakeDesk(view());
    tools = StoreToolSet(desk, clock: () => now);
  });

  Future<Map<String, Object?>> call(
    String tool, [
    Map<String, dynamic> arguments = const {},
  ]) async =>
      (await tools.call(tool, arguments, 's1'))! as Map<String, Object?>;

  List<Map<String, Object?>> list(Object? value) =>
      (value! as List).cast<Map<String, Object?>>();

  Map<String, Object?> appGroup(Map<String, Object?> answer, String bundleId) =>
      list(answer['apps']).singleWhere((g) => g['bundleId'] == bundleId);

  Map<String, Object?> onStore(Map<String, Object?> group, String store) =>
      list(group['stores']).singleWhere((s) => s['store'] == store);

  test('serves the four store tools', () {
    expect(
      [for (final s in tools.schemas) s['name']],
      ['store_apps', 'store_app', 'store_reviews', 'store_refresh'],
    );
  });

  group('store_apps', () {
    test('groups one app across both stores, attention first', () async {
      final answer = await call('store_apps');
      final apps = list(answer['apps']);
      expect(apps.first['bundleId'], 'com.popupbits.notes');
      expect(apps.first['needsAttention'], isTrue);
      final notes = appGroup(answer, 'com.popupbits.notes');
      expect(
        [for (final s in list(notes['stores'])) s['store']],
        ['app_store', 'google_play'],
      );

      final ios = onStore(notes, 'app_store');
      expect(ios['live'], {
        'version': '2.0.0',
        'build': '40',
        'track': 'App Store',
      });
      expect(list(ios['pending']).single['state'], 'In review');
      expect(ios['rating'], {'average': 4.57, 'count': 120});
      expect(ios['downloads'], {
        'unit': 'Units',
        'total14Days': 14,
        'daysCounted': 14,
        'latestDay': '2026-09-29',
      });
      expect(ios['reviews'], {
        'shown': 2,
        'unanswered': 1,
        'averageOfShown': 3.5,
      });

      final android = onStore(notes, 'google_play');
      final pending = list(android['pending']);
      expect(pending.first['state'], 'Halted');
      expect(pending.first['needsAttention'], isTrue);
      expect(pending.last['rolloutPercent'], 20.0);
      expect(android['crashRatePercent'], 1.23);
    });

    test('a missing reading is said to be missing, never a zero', () async {
      final notes = appGroup(await call('store_apps'), 'com.popupbits.notes');
      final ios = onStore(notes, 'app_store');
      expect(ios['crashRatePercent'], {
        'missing': 'notSupported',
        'message': 'App Store Connect publishes no crash rate through its API.',
      });
      final android = onStore(notes, 'google_play');
      expect((android['rating']! as Map)['missing'], 'permission');
      expect((android['anrRatePercent']! as Map)['missing'], 'noData');
      expect((android['downloads']! as Map)['missing'], 'noData');
    });

    test('an app listed but not read has every reading missing', () async {
      final tally = appGroup(await call('store_apps'), 'com.popupbits.tally');
      final entry = onStore(tally, 'google_play');
      for (final field in [
        'live',
        'pending',
        'rating',
        'downloads',
        'reviews',
      ]) {
        expect((entry[field]! as Map)['missing'], 'notRead', reason: field);
      }
    });

    test('carries the age of the reading and each store\'s state', () async {
      desk.view = view(
        playApps: ReadingMissing(
          StoreFailure.network,
          'Google Play did not answer.',
          read,
        ),
      );
      final answer = await call('store_apps');
      expect(answer['refreshedAt'], read.toIso8601String());
      expect(answer['ageMinutes'], 25);
      expect(list(answer['stores']), [
        {
          'store': 'app_store',
          'label': 'App Store',
          'checkedAt': read.toUtc().toIso8601String(),
          'apps': 2,
        },
        {
          'store': 'google_play',
          'label': 'Google Play',
          'checkedAt': read.toUtc().toIso8601String(),
          'missing': 'network',
          'message': 'Google Play did not answer.',
        },
      ]);
    });

    test('says when the stores were never read', () async {
      desk.view = view(neverRead: true);
      final answer = await call('store_apps');
      expect(answer['refreshedAt'], isNull);
      expect(answer['ageMinutes'], isNull);
      expect(answer['note'], contains('never been read'));
    });

    test('with nothing connected, points at Settings → Stores', () async {
      desk.view = view(connected: false);
      await expectLater(
        call('store_apps'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Settings → Stores'),
          ),
        ),
      );
      expect(desk.asked, isEmpty);
    });

    test('refresh: true reads a view older than ten minutes', () async {
      await call('store_apps', {'refresh': true});
      expect(desk.asked, [const Duration(minutes: 10)]);
      await call('store_apps');
      expect(desk.asked, hasLength(1));
    });
  });

  group('store_app', () {
    test('finds an app by bundle id, store id or name', () async {
      for (final query in [
        'com.popupbits.notes',
        '1234567890',
        'CALM NOTES',
        '  calm notes ',
      ]) {
        final answer = await call('store_app', {'app': query});
        expect(answer['bundleId'], 'com.popupbits.notes', reason: query);
      }
      final lite = await call('store_app', {'app': '2222222222'});
      expect(lite['bundleId'], 'com.popupbits.noteslite');
    });

    test('an ambiguous or unknown name is refused with candidates', () async {
      await expectLater(
        call('store_app', {'app': 'calm'}),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            allOf(contains('Calm Notes'), contains('com.popupbits.noteslite')),
          ),
        ),
      );
      await expectLater(
        call('store_app', {'app': 'nothing like it'}),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('com.popupbits.tally'),
          ),
        ),
      );
      await expectLater(call('store_app', {}), throwsA(isA<ArgumentError>()));
    });

    test('releases per track, vitals and downloads per day', () async {
      final answer = await call('store_app', {
        'app': 'com.popupbits.notes',
        'store': 'google_play',
      });
      final entry = list(answer['stores']).single;
      expect(entry['store'], 'google_play');
      final tracks = list(entry['releases']);
      expect([for (final t in tracks) t['track']], ['production', 'beta']);
      final beta = list(tracks.last['releases']).single;
      expect(beta['state'], 'Halted');
      expect(beta['stateCode'], 'halted');
      expect(beta['storeState'], 'halted');
      expect(beta['needsAttention'], isTrue);
      final vitals = entry['vitals']! as Map;
      expect(vitals['crashRatePercent'], 1.23);
      expect(vitals['from'], '2026-09-01T00:00:00.000Z');
      expect((entry['downloads']! as Map)['missing'], 'noData');
      expect(((entry['reviews']! as Map)['byRating'] as Map)['1'], 1);
      expect(answer['ageMinutes'], 25);
    });

    test('a store the app is not on, or not a store at all', () async {
      await expectLater(
        call('store_app', {'app': 'Tally', 'store': 'app_store'}),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        call('store_app', {'app': 'Tally', 'store': 'itunes'}),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('store_reviews', () {
    test('newest first, across both stores', () async {
      final answer = await call('store_reviews', {'app': 'Calm Notes'});
      final reviews = list(answer['reviews']);
      expect(
        [for (final r in reviews) r['body']],
        ['body p1', 'body a2', 'body p2', 'body a1'],
      );
      expect(reviews.first['store'], 'google_play');
      expect(reviews[1]['reply'], 'Thanks, fixed in 2.1.');
      expect(reviews[1]['repliedAt'], now.toIso8601String());
      expect(answer['matched'], 4);
    });

    test('filters by rating, reply and store, and limits', () async {
      final low = await call('store_reviews', {
        'app': 'com.popupbits.notes',
        'maxRating': 2,
      });
      expect([for (final r in list(low['reviews'])) r['rating']], [1, 2]);

      final open = await call('store_reviews', {
        'app': 'com.popupbits.notes',
        'unansweredOnly': true,
        'store': 'app_store',
      });
      expect([for (final r in list(open['reviews'])) r['body']], ['body a1']);

      final one = await call('store_reviews', {
        'app': 'com.popupbits.notes',
        'limit': 1,
      });
      expect(list(one['reviews']), hasLength(1));
      expect(one['matched'], 4);
    });

    test('a store whose reviews were not read says why', () async {
      final answer = await call('store_reviews', {'app': 'Tally'});
      expect(answer['reviews'], isEmpty);
      expect(list(answer['unavailable']).single['missing'], 'notRead');
    });

    test('out-of-range arguments are the caller\'s mistake', () async {
      for (final arguments in <Map<String, dynamic>>[
        {'app': 'Tally', 'maxRating': 6},
        {'app': 'Tally', 'maxRating': 0},
        {'app': 'Tally', 'limit': 101},
        {'app': 'Tally', 'limit': 2.5},
        {'app': 'Tally', 'unansweredOnly': 'yes'},
      ]) {
        await expectLater(
          call('store_reviews', arguments),
          throwsA(isA<ArgumentError>()),
          reason: '$arguments',
        );
      }
    });
  });

  group('store_refresh', () {
    test('always reads by default, and passes maxAge through', () async {
      final answer = await call('store_refresh');
      expect(desk.asked, [null]);
      expect(answer['apps'], isNotEmpty);
      await call('store_refresh', {'maxAgeMinutes': 30});
      expect(desk.asked, [null, const Duration(minutes: 30)]);
    });

    test('answers from the view the refresh returned', () async {
      desk.next = view(refreshedAt: now);
      final answer = await call('store_refresh');
      expect(answer['ageMinutes'], 0);
    });

    test('with nothing connected, the stores are not called', () async {
      desk.view = view(connected: false);
      await expectLater(call('store_refresh'), throwsA(isA<StateError>()));
      expect(desk.asked, isEmpty);
    });
  });

  test('no answer carries any credential text', () async {
    final answers = [
      await call('store_apps'),
      await call('store_app', {'app': 'com.popupbits.notes'}),
      await call('store_reviews', {'app': 'com.popupbits.notes'}),
      await call('store_refresh'),
    ];
    final text = jsonEncode(answers);
    for (final secret in [
      apple.keyId,
      apple.issuerId,
      apple.vendorNumber!,
      play.clientEmail!,
      play.reportsBucket!,
    ]) {
      expect(text, isNot(contains(secret)));
    }
  });

  test('a tool it does not serve is not answered', () {
    expect(tools.call('get_usage', const {}, 's1'), isNull);
  });
}

class _FakeDesk implements StoreDesk {
  _FakeDesk(this.view);

  @override
  StoresView view;

  /// When set, what a refresh leaves the desk holding.
  StoresView? next;

  final asked = <Duration?>[];

  @override
  Future<StoresView> refresh({Duration? maxAge}) async {
    asked.add(maxAge);
    if (next case final replaced?) view = replaced;
    return view;
  }
}
