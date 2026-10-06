import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/data/data_service.dart';
import 'package:karmashala_host/src/stores/server_store_desk.dart';
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;
import 'package:store_console/store_console.dart';
import 'package:store_console_apple/store_console_apple.dart';
import 'package:test/test.dart';

/// The server's app-store desk, driven as a client drives it — `stores.*`
/// through a [DataSession] — over fake store clients and a data folder in a
/// temp directory. No store is ever called. Test values only.
void main() {
  late Directory tmp;
  late AppDatabase database;
  late DataService data;
  late ServerStoreDesk desk;
  late DataSession client;
  late List<DataChange> told;
  late FakeStoreClient appleFake;
  late FakeStoreClient playFake;
  late DateTime now;
  late List<AppleApiKey> appleKeysBuilt;

  const pem =
      '-----BEGIN PRIVATE KEY-----\nnot-a-real-key\n-----END PRIVATE KEY-----';
  const playJson =
      '{"type":"service_account","private_key":"not-a-real-play-key",'
      '"client_email":"bot@example.iam.gserviceaccount.com"}';

  StoreApp appleApp(String id) => StoreApp(
    store: StoreKind.appStore,
    id: id,
    bundleId: 'com.example.$id',
    name: 'Apple $id',
  );
  StoreApp playApp(String id) => StoreApp(
    store: StoreKind.googlePlay,
    id: 'com.example.$id',
    bundleId: 'com.example.$id',
    name: 'Play $id',
  );

  ServerStoreDesk open() {
    final opened = ServerStoreDesk(
      dataDirectory: tmp.path,
      tell: data.announce,
      clock: () => now,
      appleClient: (key) {
        appleKeysBuilt.add(key);
        return appleFake;
      },
      playClient: (_) => playFake,
    );
    data
      ..storeWork = opened
      ..greeters.add(opened.greeting);
    return opened;
  }

  Future<R> ask<R>(DataRequest<R> request) async =>
      (await client.handleLater(request)).value;

  Future<DataRefused> refusal(
    DataRequest<Object?> request, {
    DataSession? from,
  }) async {
    try {
      await (from ?? client).handleLater(request);
    } on DataRefused catch (refused) {
      return refused;
    }
    fail('${request.kind} was not refused');
  }

  Future<void> connectApple() async {
    await ask(
      const StoreAppleSet(
        keyId: 'KEY123',
        issuerId: 'issuer-1',
        privateKeyPem: pem,
        vendorNumber: ' 8800 ',
      ),
    );
    await desk.refresh();
  }

  Future<void> connectPlay() async {
    await ask(
      const StorePlaySet(
        serviceAccountJson: playJson,
        reportsBucket: 'pubsite_prod_1',
        packageNames: ['com.example.extra'],
      ),
    );
    await desk.refresh();
  }

  File snapshotFile() => File(p.join(tmp.path, 'stores', 'snapshot.json'));

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ks-store-desk-');
    database = AppDatabase.memory();
    data = DataService(database);
    now = DateTime.utc(2026, 10, 1, 8);
    appleKeysBuilt = [];
    appleFake = FakeStoreClient(StoreKind.appStore, [
      appleApp('1'),
      appleApp('2'),
    ]);
    playFake = FakeStoreClient(StoreKind.googlePlay, [playApp('one')]);
    desk = open();
    told = [];
    client = data.open((batch) => told.addAll(batch.changes));
    client.handle(const DataSubscribe());
  });

  tearDown(() {
    desk.close();
    database.close();
    tmp.deleteSync(recursive: true);
  });

  group('all-time installs', () {
    late FakePlayClient play;
    setUp(() => playFake = play = FakePlayClient([playApp('one')]));

    Reading<InstallTotal>? installs() => desk.view.apps
        .singleWhere((a) => a.app.store == StoreKind.googlePlay)
        .allTimeInstalls;

    test('the reports\' exact count stands over the listing band', () async {
      play
        ..installs = 1234
        ..band = '1K+';
      await connectPlay();
      final total = installs()!.valueOrNull!;
      expect(total.count, 1234);
      expect(total.atLeast, isFalse);
    });

    test('without the reports the listing band is shown as a floor', () async {
      play
        ..installsFailure = const StoreException(
          StoreFailure.notConfigured,
          'Add your reports bucket in Settings → Stores.',
        )
        ..band = '10K+';
      await connectPlay();
      final total = installs()!.valueOrNull!;
      expect(total.count, 10000);
      expect(total.atLeast, isTrue);
      expect(total.band, '10K+');
      expect(total.note, contains('reports bucket'));
      expect(
        desk.view.icons['googlePlay:com.example.one']!.installBand,
        '10K+',
      );

      // The page is read daily, not every refresh; its band still stands.
      await desk.refresh();
      expect(play.listingCalls, 1);
      expect(installs()!.valueOrNull!.band, '10K+');
    });

    test('an app with no public page says so', () async {
      play
        ..installsFailure = const StoreException(
          StoreFailure.notConfigured,
          'Add your reports bucket in Settings → Stores.',
        )
        ..public = false;
      await connectPlay();
      final missing = installs()! as ReadingMissing<InstallTotal>;
      expect(missing.message, startsWith('Not on the public store'));
      expect(missing.message, contains('reports bucket'));
    });
  });

  test('a subscriber is greeted with the view, empty at first', () async {
    final greeted = told.whereType<StoresChanged>().single.view;
    expect(greeted.connected, isEmpty);
    expect(greeted.apps, isEmpty);
    // With nothing connected a refresh asks no store.
    final view = await ask(const StoresRefresh());
    expect(view.refreshedAt, isNull);
    expect(appleFake.listCalls, 0);
  });

  test('setting a key reads the stores; no answer carries a secret', () async {
    await connectApple();
    await connectPlay();
    final view = await ask(const StoresGet());
    expect(view.apple!.keyId, 'KEY123');
    expect(view.apple!.vendorNumber, '8800');
    expect(view.apple!.importedAt, now);
    expect(view.play!.clientEmail, 'bot@example.iam.gserviceaccount.com');
    expect(view.play!.packageNames, ['com.example.extra']);
    expect(view.apps.map((a) => a.app.key), {
      'appStore:1',
      'appStore:2',
      'googlePlay:com.example.one',
    });
    expect(view.refreshedAt, now);
    expect(view.refreshing, isFalse);
    expect(told.whereType<StoresProgress>(), isNotEmpty);

    final wire = jsonEncode([
      view.toJson(),
      for (final change in told) change.toJson(),
    ]);
    expect(wire, isNot(contains('not-a-real-key')));
    expect(wire, isNot(contains('not-a-real-play-key')));
  });

  test('the snapshot file keeps readings, never a credential', () async {
    await connectApple();
    await connectPlay();
    final kept = snapshotFile().readAsStringSync();
    expect(kept, isNot(contains('not-a-real-key')));
    expect(kept, isNot(contains('not-a-real-play-key')));
    expect(kept, isNot(contains('KEY123')));
    expect(kept, isNot(contains('bot@example')));
    expect((jsonDecode(kept) as Map)['version'], 1);

    // Read back at start, before any store is asked.
    desk.close();
    final calls = appleFake.listCalls;
    desk = open();
    expect(desk.view.apps, hasLength(3));
    expect(desk.view.refreshedAt, now);
    expect(appleFake.listCalls, calls);
  });

  test('a second refresh joins the one under way', () async {
    await connectApple();
    final gate = appleFake.gate = Completer<void>();
    final calls = appleFake.listCalls;
    final first = desk.refresh();
    final second = desk.refresh();
    expect(identical(first, second), isTrue);
    expect(desk.view.refreshing, isTrue);
    gate.complete();
    await first;
    expect(appleFake.listCalls, calls + 1);
    expect(desk.view.refreshing, isFalse);
  });

  test('a view younger than maxAge is answered as it is', () async {
    await connectApple();
    final calls = appleFake.listCalls;
    now = now.add(const Duration(minutes: 10));
    await ask(const StoresRefresh(maxAgeSeconds: 3600));
    expect(appleFake.listCalls, calls);
    now = now.add(const Duration(hours: 2));
    final view = await ask(const StoresRefresh(maxAgeSeconds: 3600));
    expect(appleFake.listCalls, calls + 1);
    expect(view.refreshedAt, now);
  });

  test('apps of a store that did not answer stay as last read', () async {
    await connectApple();
    await connectPlay();
    final before = now;
    now = now.add(const Duration(hours: 1));
    playFake.listFailure = const StoreException(
      StoreFailure.network,
      'The store could not be reached.',
    );
    appleFake.apps = [appleApp('1')];
    final view = await desk.refresh();
    expect(view.stores[StoreKind.googlePlay], isA<ReadingMissing<Object?>>());
    // App Store answered: its dropped app goes, and the time moves.
    expect(view.apps.map((a) => a.app.key), {
      'appStore:1',
      'googlePlay:com.example.one',
    });
    expect(view.refreshedAt, now);

    // Nothing answered: what is shown is as old as it was.
    now = now.add(const Duration(hours: 1));
    appleFake.listFailure = const StoreException(StoreFailure.auth, 'No.');
    final silent = await desk.refresh();
    expect(silent.refreshedAt, before.add(const Duration(hours: 1)));
    expect(silent.apps, hasLength(2));
  });

  test('removing a credential drops that store everywhere', () async {
    await connectApple();
    await connectPlay();
    final view = await ask(const StoreCredentialRemove(StoreKind.googlePlay));
    expect(view.play, isNull);
    expect(view.stores.keys, [StoreKind.appStore]);
    expect(view.apps.every((a) => a.app.store == StoreKind.appStore), isTrue);
    expect(told.whereType<StoresChanged>().last.view.play, isNull);
    expect(snapshotFile().readAsStringSync(), isNot(contains('googlePlay')));

    desk.close();
    desk = open();
    expect(desk.view.play, isNull);
    expect(desk.view.apps, hasLength(2));
  });

  test('a changed credential builds the console again', () async {
    await connectApple();
    expect(appleKeysBuilt, hasLength(1));
    // A refresh closes its console when it ends, so the next one builds anew
    // with the credentials held then.
    expect(appleFake.closed, isTrue);
    await desk.refresh();
    expect(appleKeysBuilt, hasLength(2));
    expect(appleKeysBuilt.last.issuerId, 'issuer-1');
    await ask(const StoreAppleSet(keyId: 'KEY123', issuerId: 'issuer-2'));
    await desk.refresh();
    expect(appleKeysBuilt, hasLength(3));
    expect(appleKeysBuilt.last.issuerId, 'issuer-2');
    // Kept the held key file and when it came in.
    expect(appleKeysBuilt.last.privateKeyPem, pem);
    expect(desk.view.apple!.importedAt, DateTime.utc(2026, 10, 1, 8));
    expect(appleFake.closed, isTrue);
  });

  test('bad credentials are refused and nothing is kept', () async {
    expect(
      (await refusal(const StoreAppleSet(keyId: 'K', issuerId: 'I'))).code,
      DataRefusalCode.invalid,
    );
    expect(
      (await refusal(
        const StoreAppleSet(keyId: 'K', issuerId: 'I', privateKeyPem: 'nope'),
      )).code,
      DataRefusalCode.invalid,
    );
    expect(
      (await refusal(const StorePlaySet(serviceAccountJson: '{"a":1}'))).code,
      DataRefusalCode.invalid,
    );
    expect(
      (await refusal(const StorePlaySet(packageNames: ['x']))).code,
      DataRefusalCode.invalid,
    );
    expect((await ask(const StoresGet())).connected, isEmpty);
    expect(
      File(p.join(tmp.path, 'secrets', 'stores.json')).existsSync(),
      isFalse,
    );
  });

  test(
    'package names are trimmed and de-duplicated, a blank bucket is none',
    () async {
      final view = await ask(
        const StorePlaySet(
          serviceAccountJson: playJson,
          reportsBucket: '  ',
          packageNames: [' com.a ', 'com.a', '', 'com.b'],
        ),
      );
      expect(view.play!.packageNames, ['com.a', 'com.b']);
      expect(view.play!.reportsBucket, isNull);
      await desk.refresh();
    },
  );

  test(
    'a phone reads and refreshes, and may not change a credential',
    () async {
      final phone = data.open((_) {}, phone: true);
      for (final request in <DataRequest<Object?>>[
        const StoreAppleSet(keyId: 'K', issuerId: 'I', privateKeyPem: pem),
        const StorePlaySet(serviceAccountJson: playJson),
        const StoreCredentialRemove(StoreKind.appStore),
      ]) {
        expect(
          (await refusal(request, from: phone)).code,
          DataRefusalCode.denied,
        );
      }
      await phone.handleLater(const StoresGet());
      await phone.handleLater(const StoresRefresh());
    },
  );

  test('an unreadable snapshot is nothing kept, not a crash', () {
    snapshotFile().parent.createSync(recursive: true);
    snapshotFile().writeAsStringSync('not json');
    desk.close();
    desk = open();
    expect(desk.view.apps, isEmpty);
    snapshotFile().writeAsStringSync('{"version":9,"view":{}}');
    desk.close();
    desk = open();
    expect(desk.view.apps, isEmpty);
  });

  test('a server without a desk refuses the work as unavailable', () async {
    data.storeWork = null;
    expect(
      (await refusal(const StoresGet())).code,
      DataRefusalCode.unavailable,
    );
  });

  group('one app at a time', () {
    /// What a client holds after every change told so far, folded as the
    /// app's data client folds them.
    StoresView seen() {
      var view = const StoresView();
      for (final change in told) {
        switch (change) {
          case StoresChanged(view: final next):
            view = next;
          case final StoreAppChanged change:
            view = view.withApp(change);
          default:
        }
      }
      return view;
    }

    Future<void> settle() => Future<void>.delayed(Duration.zero);

    test('each app is told as it is read, not when the slowest is', () async {
      await connectApple();
      final slow = appleFake.appGates['2'] = Completer<void>();
      told.clear();
      final refresh = desk.refresh();
      for (var i = 0; i < 5; i++) {
        await settle();
      }
      final midway = seen();
      expect(midway.refreshing, isTrue);
      expect(midway.apps.map((a) => a.app.key), contains('appStore:1'));
      expect(midway.reads.containsKey('appStore:1'), isFalse);
      expect(midway.reads['appStore:2']!.phase, StoreAppReadPhase.reading);
      slow.complete();
      await refresh;
      final after = seen();
      expect(after.refreshing, isFalse);
      expect(after.reads, isEmpty);
      expect(after.apps, hasLength(2));
    });

    test('apps past the concurrency wait queued', () async {
      appleFake.apps = [for (var i = 1; i <= 6; i++) appleApp('$i')];
      for (var i = 1; i <= 6; i++) {
        appleFake.appGates['$i'] = Completer<void>();
      }
      await connectAppleWithoutWaiting(ask);
      for (var i = 0; i < 5; i++) {
        await settle();
      }
      final phases = seen().reads.values.map((read) => read.phase).toList();
      expect(
        phases.where((phase) => phase == StoreAppReadPhase.reading),
        hasLength(ServerStoreDesk.concurrency),
      );
      expect(
        phases.where((phase) => phase == StoreAppReadPhase.queued),
        hasLength(6 - ServerStoreDesk.concurrency),
      );
      for (final gate in appleFake.appGates.values) {
        gate.complete();
      }
      await desk.refresh();
      expect(seen().reads, isEmpty);
    });

    test('a store\'s apps are read while the other still lists', () async {
      await connectApple();
      await connectPlay();
      final listing = appleFake.gate = Completer<void>();
      told.clear();
      final refresh = desk.refresh();
      for (var i = 0; i < 5; i++) {
        await settle();
      }
      expect(
        told.whereType<StoreAppChanged>().where(
          (change) =>
              change.app.store == StoreKind.googlePlay &&
              change.snapshot != null,
        ),
        isNotEmpty,
      );
      listing.complete();
      await refresh;
    });

    test(
      'an app whose every reading fails is failed, and keeps what it had',
      () async {
        await connectApple();
        now = now.add(const Duration(hours: 1));
        appleFake.appFailures['2'] = const StoreException(
          StoreFailure.network,
          'The store could not be reached.',
        );
        final view = await desk.refresh();
        final failed = view.reads['appStore:2']!;
        expect(failed.phase, StoreAppReadPhase.failed);
        expect(failed.message, 'The store could not be reached.');
        expect(failed.at, now);
        expect(view.reads.containsKey('appStore:1'), isFalse);
        // The numbers read an hour ago stay on show beside the failure.
        final kept = view.apps.singleWhere((a) => a.app.key == 'appStore:2');
        expect(kept.rating.valueOrNull, isNotNull);
        expect(kept.releases.checkedAt, now.subtract(const Duration(hours: 1)));
        expect(seen().reads['appStore:2']!.phase, StoreAppReadPhase.failed);
      },
    );

    test(
      'stores.refresh.app reads that app alone and clears its failure',
      () async {
        await connectApple();
        appleFake.appFailures['2'] = const StoreException(
          StoreFailure.server,
          'The store answered with an error.',
        );
        await desk.refresh();
        expect(desk.view.reads['appStore:2']!.phase, StoreAppReadPhase.failed);
        appleFake.appFailures.clear();
        appleFake.releasesAsked.clear();
        now = now.add(const Duration(minutes: 1));
        final view = await ask(
          const StoresRefreshApp(store: StoreKind.appStore, id: '2'),
        );
        expect(appleFake.releasesAsked, ['2']);
        expect(view.reads, isEmpty);
        expect(
          view.apps
              .singleWhere((a) => a.app.key == 'appStore:2')
              .releases
              .checkedAt,
          now,
        );
        expect(seen().reads, isEmpty);
        expect(
          (await refusal(
            const StoresRefreshApp(store: StoreKind.appStore, id: 'nine'),
          )).code,
          DataRefusalCode.invalid,
        );
      },
    );

    test('with maxAge, an app read since is not read again', () async {
      await connectApple();
      now = now.add(const Duration(hours: 2));
      await ask(const StoresRefreshApp(store: StoreKind.appStore, id: '1'));
      appleFake.releasesAsked.clear();
      now = now.add(const Duration(minutes: 5));
      await ask(const StoresRefresh(maxAgeSeconds: 3600));
      expect(appleFake.releasesAsked, ['2']);
      // Asked by hand, every app is read.
      appleFake.releasesAsked.clear();
      await ask(const StoresRefresh());
      expect(appleFake.releasesAsked.toSet(), {'1', '2'});
    });

    test('an app\'s icon does not hold its numbers back', () async {
      final play = FakePlayClient([playApp('one')]);
      playFake = play;
      final page = play.listingGate = Completer<void>();
      await ask(
        const StorePlaySet(
          serviceAccountJson: playJson,
          reportsBucket: 'pubsite_prod_1',
        ),
      );
      for (var i = 0; i < 5; i++) {
        await settle();
      }
      expect(
        seen().apps.map((a) => a.app.key),
        contains('googlePlay:com.example.one'),
      );
      page.complete();
      await desk.refresh();
      expect(seen().icons, contains('googlePlay:com.example.one'));
    });

    test('the kept snapshot holds no read states', () async {
      await connectApple();
      appleFake.appFailures['1'] = const StoreException(
        StoreFailure.network,
        'Unreachable.',
      );
      await desk.refresh();
      expect(desk.view.reads, isNotEmpty);
      expect(
        ((jsonDecode(snapshotFile().readAsStringSync()) as Map)['view'] as Map)
            .containsKey('reads'),
        isFalse,
      );
    });
  });
}

/// Sets the App Store key and leaves the read it starts running.
Future<void> connectAppleWithoutWaiting(
  Future<R> Function<R>(DataRequest<R> request) ask,
) => ask(
  const StoreAppleSet(
    keyId: 'KEY123',
    issuerId: 'issuer-1',
    privateKeyPem:
        '-----BEGIN PRIVATE KEY-----\nnot-a-real-key\n-----END PRIVATE KEY-----',
  ),
);

/// A store that answers from memory.
class FakeStoreClient implements StoreClient {
  FakeStoreClient(this.store, this.apps);

  @override
  final StoreKind store;

  List<StoreApp> apps;
  StoreException? listFailure;
  Completer<void>? gate;
  int listCalls = 0;
  bool closed = false;

  /// By app id: its releases wait for the gate, and every reading the store
  /// would count as a fault throws the failure.
  final appGates = <String, Completer<void>>{};
  final appFailures = <String, StoreException>{};

  /// The ids whose releases were asked for, in order.
  final releasesAsked = <String>[];

  void _failIfAsked(StoreApp app) {
    final failure = appFailures[app.id];
    if (failure != null) throw failure;
  }

  @override
  Future<List<StoreApp>> listApps() async {
    listCalls++;
    final waiting = gate;
    if (waiting != null) await waiting.future;
    final failure = listFailure;
    if (failure != null) throw failure;
    return apps;
  }

  @override
  Future<List<StoreRelease>> releases(StoreApp app) async {
    releasesAsked.add(app.id);
    if (appGates[app.id] case final gate?) await gate.future;
    _failIfAsked(app);
    return [
      const StoreRelease(
        track: 'production',
        version: '1.0.0',
        state: ReleaseState.live,
        rawState: 'LIVE',
      ),
    ];
  }

  @override
  Future<List<StoreReview>> reviews(StoreApp app) async {
    _failIfAsked(app);
    return const [];
  }

  @override
  Future<RatingSummary> rating(StoreApp app) async {
    _failIfAsked(app);
    return const RatingSummary(average: 4.5, count: 10);
  }

  @override
  Future<VitalsSummary> vitals(StoreApp app) =>
      throw const StoreException(StoreFailure.notSupported, 'Not here.');

  @override
  Future<DownloadSeries> downloads(StoreApp app) =>
      throw const StoreException(StoreFailure.notConfigured, 'Not set up.');

  @override
  Future<StoreIconImage?> icon(StoreApp app) async => null;

  @override
  void close() => closed = true;
}

/// A Play that counts all-time installs and reads its public page.
class FakePlayClient extends FakeStoreClient
    implements StoreInstallTotalSource, StoreListingSource {
  FakePlayClient(List<StoreApp> apps) : super(StoreKind.googlePlay, apps);

  StoreException? installsFailure;
  int installs = 0;
  String? band;
  bool public = true;
  int listingCalls = 0;
  Completer<void>? listingGate;

  @override
  Future<InstallTotal> allTimeInstalls(StoreApp app) async {
    final failure = installsFailure;
    if (failure != null) throw failure;
    return InstallTotal(
      count: installs,
      measure: 'user installs',
      source: InstallTotalSource.reports,
      since: '2024-03',
    );
  }

  @override
  Future<StoreListing?> listing(StoreApp app) async {
    listingCalls++;
    if (listingGate case final gate?) await gate.future;
    return public ? StoreListing(installBand: band) : null;
  }
}
