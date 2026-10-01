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
}

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
  Future<List<StoreRelease>> releases(StoreApp app) async => [
    const StoreRelease(
      track: 'production',
      version: '1.0.0',
      state: ReleaseState.live,
      rawState: 'LIVE',
    ),
  ];

  @override
  Future<List<StoreReview>> reviews(StoreApp app) async => const [];

  @override
  Future<RatingSummary> rating(StoreApp app) async =>
      const RatingSummary(average: 4.5, count: 10);

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
