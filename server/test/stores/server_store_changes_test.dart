import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/data/data_service.dart';
import 'package:karmashala_host/src/stores/server_store_desk.dart';
import 'package:karmashala_host/src/stores/store_change_inbox.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;
import 'package:store_console/store_console.dart';
import 'package:test/test.dart';

/// What changed between two refreshes, told and kept by the server's store
/// desk: over scripted fake stores, a fake clock and a fake timer, in a temp
/// data folder. No store is ever called. Test values only.
void main() {
  late Directory tmp;
  late AppDatabase database;
  late DataService data;
  late DataSession client;
  late ServerStoreDesk desk;
  late _ScriptedStore apple;
  late DateTime now;
  late List<DataChange> told;
  late List<List<StoreAppChanges>> filed;
  late List<Set<String>> seen;
  late List<String> logged;
  late List<_FakeTimer> timers;

  const pem =
      '-----BEGIN PRIVATE KEY-----\nnot-a-real-key-r71\n-----END PRIVATE KEY-----';
  const one = StoreApp(
    store: StoreKind.appStore,
    id: '1',
    bundleId: 'com.example.one',
    name: 'One',
  );
  const two = StoreApp(
    store: StoreKind.appStore,
    id: '2',
    bundleId: 'com.example.two',
    name: 'Two',
  );

  ServerStoreDesk open() {
    final opened =
        ServerStoreDesk(
            dataDirectory: tmp.path,
            tell: data.announce,
            clock: () => now,
            log: logged.add,
            appleClient: (_) => apple,
            timer: (wait, fire) {
              final timer = _FakeTimer(wait, fire);
              timers.add(timer);
              return timer;
            },
            random: _NoJitter(),
          )
          ..onChanges = filed.add
          ..onSeen = seen.add;
    data
      ..storeWork = opened
      ..greeters.add(opened.greeting);
    return opened;
  }

  Future<R> ask<R>(DataRequest<R> request) async =>
      (await client.handleLater(request)).value;

  Future<void> connect() async {
    await ask(
      const StoreAppleSet(
        keyId: 'KEY123',
        issuerId: 'issuer-1',
        privateKeyPem: pem,
      ),
    );
    // The import starts a read of its own; wait it out.
    await desk.refresh();
  }

  Future<StoresView> later() {
    now = now.add(const Duration(hours: 3));
    return desk.refresh();
  }

  List<StoreChangesNoticed> notices() =>
      told.whereType<StoreChangesNoticed>().toList();

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ks-store-changes-');
    database = AppDatabase.memory();
    data = DataService(database);
    now = DateTime.utc(2026, 10, 9, 8);
    apple = _ScriptedStore(StoreKind.appStore, [one, two]);
    told = [];
    filed = [];
    seen = [];
    logged = [];
    timers = [];
    desk = open();
    client = data.open((batch) => told.addAll(batch.changes));
    client.handle(const DataSubscribe());
  });

  tearDown(() {
    desk.close();
    database.close();
    tmp.deleteSync(recursive: true);
  });

  test('the first read after connecting a store tells nothing', () async {
    apple.releasesOf[one.id] = [
      _release('1.0', ReleaseState.inReview, 'IN_REVIEW'),
    ];
    await connect();
    expect(notices(), isEmpty);
    expect(filed, isEmpty);
    expect(desk.view.changes, isEmpty);
  });

  test('a change is told once, for the app that changed alone', () async {
    apple.releasesOf[one.id] = [
      _release(
        '1.34.4',
        ReleaseState.pendingRelease,
        'PENDING_DEVELOPER_RELEASE',
      ),
    ];
    apple.reviewsOf[one.id] = [_review('a', 5, now)];
    await connect();
    told.clear();

    apple.releasesOf[one.id] = [
      _release('1.34.4', ReleaseState.live, 'READY_FOR_SALE'),
    ];
    apple.reviewsOf[one.id] = [
      _review('c', 2, now.add(const Duration(hours: 2))),
      _review('b', 4, now.add(const Duration(hours: 1))),
      _review('d', 5, now.add(const Duration(hours: 1))),
      _review('a', 5, now),
    ];
    final view = await later();

    expect(filed, hasLength(1), reason: 'one inbox batch per refresh');
    final found = filed.single.single;
    expect(found.app, one);
    expect(
      found.sentence,
      'One (iOS): 3 new reviews (lowest 2★) · 1.34.4 Approved → Ready for sale',
    );
    expect(notices(), hasLength(1));
    expect(notices().single.changes.single.summary, found.summary);
    expect(view.changesOf(one.key)?.seen, isFalse);
    expect(view.changesOf(two.key), isNull);

    // The same read again is not news.
    filed.clear();
    told.clear();
    await later();
    expect(filed, isEmpty);
    expect(notices(), isEmpty);
  });

  test('an inbox item per app, attention only when a change wants it', () {
    StoreAppChanges changes(bool attention) => StoreAppChanges(
      app: one,
      platform: 'iOS',
      at: now,
      changes: [
        StoreChange(
          kind: StoreChangeKind.release,
          text: '1.0 In review → Rejected',
          attention: attention,
        ),
      ],
    );
    final loud = storeChangesInboxItem(changes(true));
    final quiet = storeChangesInboxItem(changes(false));
    expect(loud.kind, InboxItemKind.storeAttention);
    expect(quiet.kind, InboxItemKind.storeNews);
    expect(loud.kind.isQuiet, isFalse);
    expect(quiet.kind.isQuiet, isTrue);
    expect(loud.label, 'One (iOS)');
    expect(loud.detail, '1.0 In review → Rejected');
    expect(storeAppKeyOfInboxId(loud.session.openId), one.key);
    // Travels to a released client as a kind it knows.
    expect(loud.toJson()['kind'], 'followUp');
    expect(
      InboxItem.fromJson(loud.toJson()).kind,
      InboxItemKind.storeAttention,
    );
  });

  test('what was compared survives a restart, and so does the log', () async {
    apple.releasesOf[one.id] = [
      _release('2.0', ReleaseState.inReview, 'IN_REVIEW'),
    ];
    await connect();
    desk.close();

    apple.releasesOf[one.id] = [
      _release('2.0', ReleaseState.rejected, 'REJECTED'),
    ];
    desk = open();
    told.clear();
    await later();
    expect(filed.single.single.summary, '2.0 In review → Rejected');
    expect(filed.single.single.attention, isTrue);
    desk.close();

    desk = open();
    expect(desk.view.changesOf(one.key)?.summary, '2.0 In review → Rejected');
    expect(desk.changesSince(unseenOnly: true), hasLength(1));
  });

  test('opening an app sees its changes, here and in the inbox', () async {
    apple.reviewsOf[one.id] = [];
    await connect();
    apple.reviewsOf[one.id] = [_review('a', 1, now)];
    await later();
    expect(desk.changesSince(unseenOnly: true), hasLength(1));

    final view = await ask(StoresSeen([one.key]));
    expect(view.changesOf(one.key)?.seen, isTrue);
    expect(seen.single, {one.key});
    expect(desk.changesSince(unseenOnly: true), isEmpty);
    expect(
      desk.changesSince(since: now.subtract(const Duration(days: 1))),
      hasLength(1),
    );
  });

  test('a removed store takes its changes with it', () async {
    await connect();
    apple.reviewsOf[one.id] = [_review('a', 1, now)];
    await later();
    expect(desk.view.changes, isNotEmpty);
    await ask(const StoreCredentialRemove(StoreKind.appStore));
    expect(desk.view.changes, isEmpty);
    expect(desk.changesSince(), isEmpty);
  });

  group('the background read', () {
    _FakeTimer armed() => timers.lastWhere((timer) => timer.isActive);

    test(
      'runs every three hours by default once a store is connected',
      () async {
        desk.startSchedule();
        expect(timers.where((timer) => timer.isActive), isEmpty);
        await connect();
        expect(desk.view.schedule?.every, const Duration(hours: 3));
        expect(armed().wait, const Duration(hours: 3));

        final before = apple.listCalls;
        now = now.add(const Duration(hours: 3));
        armed().fire();
        // The fired read is under way: this joins it rather than starting one.
        expect(desk.view.refreshing, isTrue);
        await desk.refresh();
        expect(apple.listCalls, before + 1);
      },
    );

    test('the interval chosen is kept, and an odd one refused', () async {
      desk.startSchedule();
      await connect();
      final view = await ask(const StoresScheduleSet(Duration(hours: 12)));
      expect(view.schedule?.every, const Duration(hours: 12));
      expect(armed().wait, const Duration(hours: 12));

      await expectLater(
        ask(const StoresScheduleSet(Duration(hours: 2))),
        throwsA(isA<DataRefused>()),
      );

      await ask(const StoresScheduleSet(Duration.zero));
      expect(timers.where((timer) => timer.isActive), isEmpty);
      expect(desk.view.schedule?.off, isTrue);

      desk.close();
      desk = open();
      expect(desk.view.schedule?.every, Duration.zero);
    });

    test('a read that reaches no store backs off', () async {
      desk.startSchedule();
      await connect();
      apple.listFailure = const StoreException(
        StoreFailure.network,
        'The store did not answer.',
      );
      await later();
      expect(armed().wait, const Duration(hours: 6));
      await later();
      expect(armed().wait, const Duration(hours: 12));
      apple.listFailure = null;
      await later();
      expect(armed().wait, const Duration(hours: 3));
    });
  });

  test('no credential reaches a change, a log line or the kept file', () async {
    apple.releasesOf[one.id] = [
      _release('1.0', ReleaseState.inReview, 'IN_REVIEW'),
    ];
    await connect();
    apple.releasesOf[one.id] = [
      _release('1.0', ReleaseState.rejected, 'REJECTED'),
    ];
    apple.reviewsOf[one.id] = [_review('a', 1, now)];
    await later();
    await ask(StoresSeen([one.key]));

    final kept = File(
      p.join(tmp.path, 'stores', ServerStoreDesk.watchFileName),
    ).readAsStringSync();
    final everything = [
      jsonEncode([for (final change in told) change.toJson()]),
      jsonEncode([
        for (final batch in filed)
          for (final c in batch) c.toJson(),
      ]),
      jsonEncode([
        for (final batch in filed)
          for (final c in batch) storeChangesInboxItem(c).toJson(),
      ]),
      ...logged,
      kept,
    ].join('\n');
    expect(filed, isNotEmpty);
    for (final secret in ['not-a-real-key-r71', 'PRIVATE KEY']) {
      expect(everything, isNot(contains(secret)));
    }
  });
}

StoreRelease _release(String version, ReleaseState state, String raw) =>
    StoreRelease(
      track: 'App Store',
      version: version,
      state: state,
      rawState: raw,
    );

StoreReview _review(String id, int rating, DateTime at) =>
    StoreReview(id: id, rating: rating, body: 'Body $id', createdAt: at);

/// A store whose answers each test writes.
class _ScriptedStore implements StoreClient {
  _ScriptedStore(this.store, this.apps);

  @override
  final StoreKind store;
  final List<StoreApp> apps;
  final releasesOf = <String, List<StoreRelease>>{};
  final reviewsOf = <String, List<StoreReview>>{};
  StoreException? listFailure;
  int listCalls = 0;

  @override
  Future<List<StoreApp>> listApps() async {
    listCalls++;
    if (listFailure case final failure?) throw failure;
    return apps;
  }

  @override
  Future<List<StoreRelease>> releases(StoreApp app) async =>
      releasesOf[app.id] ?? const [];

  @override
  Future<List<StoreReview>> reviews(StoreApp app) async =>
      reviewsOf[app.id] ?? const [];

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
  void close() {}
}

class _FakeTimer implements Timer {
  _FakeTimer(this.wait, this._fire);

  final Duration wait;
  final void Function() _fire;
  bool _active = true;

  void fire() {
    if (!_active) return;
    _active = false;
    _fire();
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}

class _NoJitter implements math.Random {
  @override
  double nextDouble() => 0;

  @override
  bool nextBool() => false;

  @override
  int nextInt(int max) => 0;
}
