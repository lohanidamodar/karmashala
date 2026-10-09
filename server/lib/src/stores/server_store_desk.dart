import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_mcp/access.dart'
    show HandshakePermissions, SystemHandshakePermissions;
import 'package:path/path.dart' as p;
import 'package:store_console/store_console.dart';
import 'package:store_console_apple/store_console_apple.dart';
import 'package:store_console_play/store_console_play.dart';

import 'server_store_vault.dart';
import 'store_desk.dart';
import 'store_digest.dart';
import 'store_refresh_timer.dart';

/// The app stores as this server reads them, with the credentials in
/// [ServerStoreVault]. It reads them when asked, and on its own every so
/// often once [startSchedule] is called ([StoreRefreshTimer]).
class ServerStoreDesk implements StoreDesk, StoreWork {
  ServerStoreDesk({
    required String dataDirectory,
    required void Function(List<DataChange> changes) tell,
    void Function(String message)? log,
    DateTime Function()? clock,
    HandshakePermissions permissions = const SystemHandshakePermissions(),
    StoreClient Function(AppleApiKey key)? appleClient,
    StoreClient Function(PlayAccount account)? playClient,
    Timer Function(Duration wait, void Function() fire)? timer,
    math.Random? random,
  }) : _vault = ServerStoreVault(
         dataDirectory: dataDirectory,
         permissions: permissions,
       ),
       _snapshotFile = File(
         p.join(dataDirectory, snapshotDirectoryName, snapshotFileName),
       ),
       _iconDirectory = Directory(
         p.join(dataDirectory, snapshotDirectoryName, iconDirectoryName),
       ),
       _linksFile = File(
         p.join(dataDirectory, snapshotDirectoryName, linksFileName),
       ),
       _watchFile = File(
         p.join(dataDirectory, snapshotDirectoryName, watchFileName),
       ),
       _tell = tell,
       _log = log ?? _silent,
       _now = clock ?? _utcNow,
       _appleClient = appleClient,
       _playClient = playClient {
    _loadSnapshot();
    _loadLinks();
    _loadWatch();
    _schedule = StoreRefreshTimer(
      every: () => _every,
      connected: () => _connected.isNotEmpty && !_closed,
      running: () => _running != null,
      lastRefreshedAt: () => _refreshedAt,
      refresh: () =>
          unawaited(refresh().then<void>((_) {}, onError: (Object _) {})),
      now: _now,
      timer: timer,
      random: random,
      log: _log,
    );
  }

  static const String snapshotDirectoryName = 'stores';
  static const String snapshotFileName = 'snapshot.json';
  static const int _snapshotVersion = 1;

  /// The apps combined by hand. Beside the snapshot but not in it: the
  /// snapshot is a cache, dropped when unreadable or of another version;
  /// these are the owner's word, and outlive a credential being replaced.
  static const String linksFileName = 'links.json';
  static const int _linksVersion = 1;

  /// What changed and what each app looked like when last compared, and the
  /// background refresh's interval. Beside the snapshot, not in it: dropping
  /// the cache must not make the next read's changes look like news.
  static const String watchFileName = 'changes.json';
  static const int _watchVersion = 1;

  /// How many change sets are kept, and for how long, for `store_changes`.
  static const int changeLogLimit = 200;
  static const Duration changeLogAge = Duration(days: 30);

  /// How many apps are read at once.
  static const int concurrency = 4;

  /// Where each app's icon is kept: `<store>-<app id><ext>`.
  static const String iconDirectoryName = 'icons';

  /// An icon is looked up again after this long; until then the kept one,
  /// or the known absence of one, stands.
  static const Duration iconMaxAge = Duration(days: 1);

  /// A lookup that failed is tried again after this long, keeping what it
  /// had meanwhile.
  static const Duration iconRetry = Duration(hours: 1);

  /// The most one app's icon may add to a refresh.
  static const Duration iconBudget = Duration(seconds: 25);

  final ServerStoreVault _vault;
  final File _snapshotFile;
  final Directory _iconDirectory;
  final File _linksFile;
  final File _watchFile;
  final void Function(List<DataChange> changes) _tell;

  /// Change sets found by a read, for the inbox and a phone; set once the
  /// server's attention is up.
  void Function(List<StoreAppChanges> found)? onChanges;

  /// Apps opened: their inbox items are seen too.
  void Function(Set<String> appKeys)? onSeen;

  late final StoreRefreshTimer _schedule;

  /// By [StoreApp.key]: what each app looked like when last compared.
  final _digests = <String, StoreDigest>{};

  /// Oldest first.
  final _changeLog = <StoreAppChanges>[];

  /// Null until the person chooses, which is [StoreRefreshSchedule.standard].
  Duration? _everyChosen;
  Duration get _every => _everyChosen ?? StoreRefreshSchedule.standard;
  Future<void> _watchWrites = Future<void>.value();
  final void Function(String message) _log;
  final DateTime Function() _now;
  final StoreClient Function(AppleApiKey key)? _appleClient;
  final StoreClient Function(PlayAccount account)? _playClient;

  /// The finished report periods the all-time counts are made of, read once
  /// and kept with the snapshot: a console lasts one refresh, these outlive
  /// it.
  var _salesLedger = AppleSalesLedger();
  var _installMonths = PlayInstallMonths();

  /// The Play access token, good for an hour, kept across refreshes.
  var _playTokens = PlayTokens();

  final _stores = <StoreKind, Reading<List<StoreApp>>>{};
  final _apps = <String, StoreAppSnapshot>{};

  /// By [StoreApp.key]; kept with the snapshot.
  final _icons = <String, StoreAppIcon>{};

  /// When an app's icon lookup last failed; not kept across starts.
  final _iconFailedAt = <String, DateTime>{};

  /// Kept in [_linksFile]; at most one per app.
  final _links = <StoreAppLink>[];
  Future<void> _linkWrites = Future<void>.value();
  DateTime? _refreshedAt;

  Future<StoresView>? _running;

  /// Kept across refreshes: the Apple client caches sales reports.
  StoreConsole? _console;

  /// Consoles replaced while a read was using them; closed when the last
  /// read ends.
  final _retired = <StoreConsole>[];
  int _consoleUsers = 0;

  /// By [StoreApp.key]: each app's place in a read under way, or why its
  /// last read failed. Not kept with the snapshot.
  final _reads = <String, StoreAppRead>{};

  Future<void> _snapshotWrites = Future<void>.value();
  bool _closed = false;

  static void _silent(String _) {}
  static DateTime _utcNow() => DateTime.now().toUtc();

  Set<StoreKind> get _connected => {
    if (_vault.apple != null) StoreKind.appStore,
    if (_vault.play != null) StoreKind.googlePlay,
  };

  @override
  StoresView get view {
    final apple = _vault.apple;
    final play = _vault.play;
    final connected = _connected;
    return StoresView(
      apple: apple == null
          ? null
          : AppleKeySummary(
              keyId: apple.key.keyId,
              issuerId: apple.key.issuerId,
              vendorNumber: apple.key.vendorNumber,
              importedAt: apple.importedAt,
            ),
      play: play == null
          ? null
          : PlayAccountSummary(
              clientEmail: play.account.clientEmail,
              reportsBucket: play.account.reportsBucket,
              packageNames: List.unmodifiable(play.account.packageNames),
              importedAt: play.importedAt,
            ),
      stores: {
        for (final MapEntry(:key, :value) in _stores.entries)
          if (connected.contains(key)) key: value,
      },
      apps: [
        for (final app in _apps.values)
          if (connected.contains(app.app.store)) app,
      ],
      icons: {
        for (final MapEntry(:key, :value) in _icons.entries)
          if (connected.contains(_storeOfKey(key))) key: value,
      },
      links: List.unmodifiable(_links),
      refreshedAt: _refreshedAt,
      refreshing: _running != null,
      reads: {
        for (final MapEntry(:key, :value) in _reads.entries)
          if (connected.contains(_storeOfKey(key))) key: value,
      },
      changes: [
        for (final held in _latestChanges().values)
          if (connected.contains(held.app.store)) held,
      ],
      schedule: StoreRefreshSchedule(every: _every, nextAt: _schedule.nextAt),
    );
  }

  /// Each app's newest change set.
  Map<String, StoreAppChanges> _latestChanges() => {
    for (final held in _changeLog) held.app.key: held,
  };

  /// Change sets read since [since], newest first; only those not yet seen
  /// with [unseenOnly]. For an agent's `store_changes`.
  @override
  List<StoreAppChanges> changesSince({
    DateTime? since,
    bool unseenOnly = false,
  }) => [
    for (final held in _changeLog.reversed)
      if (_connected.contains(held.app.store) &&
          (since == null || !held.at.isBefore(since)) &&
          (!unseenOnly || !held.seen))
        held,
  ];

  /// Starts the background refresh; a server that never calls this reads the
  /// stores only when asked.
  void startSchedule() => _schedule.start();

  /// What a client that has just subscribed is told.
  List<DataChange> greeting() => [StoresChanged(view)];

  @override
  Future<StoresView> refresh({Duration? maxAge}) {
    final running = _running;
    if (running != null) return running;
    final at = _refreshedAt;
    // A store connected since is never fresh, whatever the others' age.
    final unread = _connected.any((store) => !_stores.containsKey(store));
    if (maxAge != null &&
        at != null &&
        !unread &&
        _now().difference(at) < maxAge) {
      return Future.value(view);
    }
    if (_connected.isEmpty || _closed) return Future.value(view);
    final done = Completer<StoresView>();
    _running = done.future;
    _guarded(
      () => _run(maxAge),
    ).then(done.complete, onError: done.completeError);
    return done.future;
  }

  /// Runs [work] in a guarded zone: Dart's HttpClient raises some failures
  /// with no request to fail — Google answering on an idle pooled connection
  /// ("unsolicited response without request", seen 2026-10-01) — as uncaught
  /// errors, and an uncaught error ends the server. Here one is logged and
  /// the work's own calls fail or finish as they would.
  Future<T> _guarded<T>(Future<T> Function() work) {
    final done = Completer<T>();
    runZonedGuarded(
      () => work().then(done.complete, onError: done.completeError),
      (error, _) => _log(
        'stores: set aside a stray network error (${error.runtimeType})',
      ),
    );
    return done.future;
  }

  @override
  Future<StoresView> handle(
    StoreRequest<Object?> request,
  ) async => switch (request) {
    StoresGet() => view,
    StoresRefresh(:final maxAgeSeconds) => await refresh(
      maxAge: maxAgeSeconds == null ? null : Duration(seconds: maxAgeSeconds),
    ),
    final StoresRefreshApp r => await _readOne(r),
    final StoreAppleSet r => await _setApple(r),
    final StorePlaySet r => await _setPlay(r),
    StoreCredentialRemove(:final store) => await _remove(store),
    final StoreAppsLink r => await _link(r),
    final StoreAppsUnlink r => await _unlink(r),
    StoresSeen(:final appKeys) => await _seen(appKeys.toSet()),
    StoresScheduleSet(:final every) => await _setEvery(every),
    _ => throw DataRefused.invalid('${request.kind} is not a store request'),
  };

  void close() {
    _closed = true;
    _schedule.stop();
    _console?.close();
    _console = null;
    for (final console in _retired) {
      console.close();
    }
    _retired.clear();
  }

  /// Reads each store's apps as that store lists them — one store's apps do
  /// not wait for the other's list — [concurrency] at a time, telling each
  /// app as it moves. With [maxAge], an app read since is left as it is.
  Future<StoresView> _run(Duration? maxAge) async {
    _tell([StoresChanged(view)]);
    // What a store said with a key since replaced is not written back.
    final started = {for (final store in StoreKind.values) store: _gen(store)};
    bool current(StoreKind store) => _gen(store) == started[store];
    final console = _takeConsole();
    final mine = <String>{};
    final found = <StoreAppChanges>[];
    var answered = 0;
    try {
      final queue = Queue<StoreApp>();
      var listing = console.clients.length;
      var arrived = Completer<void>();
      var done = 0;
      var total = 0;

      void listed(StoreAppsReading reading) {
        final store = reading.store;
        if (current(store)) {
          _stores[store] = reading.apps;
          // A store that did not answer leaves its apps as last read.
          if (reading.apps case ReadingValue(value: final apps)) {
            answered++;
            _dropUnlisted(store, apps);
            for (final app in apps) {
              if (!_due(app, maxAge)) continue;
              _reads[app.key] = const StoreAppRead.queued();
              mine.add(app.key);
              queue.add(app);
              total++;
            }
          }
          _tell([StoresChanged(view)]);
        }
      }

      for (final reading in console.listEach()) {
        unawaited(
          reading.then(listed).whenComplete(() {
            listing--;
            final wake = arrived;
            arrived = Completer<void>();
            wake.complete();
          }),
        );
      }

      Future<void> worker() async {
        while (true) {
          if (queue.isNotEmpty) {
            final changed = await _readApp(
              console,
              queue.removeFirst(),
              current,
            );
            if (changed != null) found.add(changed);
            done++;
            _tell([StoresProgress(done: done, total: total)]);
          } else if (listing == 0) {
            return;
          } else {
            await arrived.future;
          }
        }
      }

      await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);
      if (answered > 0) _refreshedAt = _now();
      _log(
        'stores: read $done app(s); '
        '$answered of ${console.clients.length} store(s) answered',
      );
    } on Object catch (error) {
      _log('stores: the refresh stopped (${error.runtimeType})');
    } finally {
      _running = null;
      _reads.removeWhere(
        (key, read) =>
            mine.contains(key) && read.phase != StoreAppReadPhase.failed,
      );
      _releaseConsole();
      _dropDisconnected();
      await _persist();
      await _announce(found);
      _schedule.refreshed(answered: answered > 0);
      _tell([StoresChanged(view)]);
    }
    return view;
  }

  /// Whether [app] is to be read in a refresh asked with [maxAge]: always
  /// without one; with one, when never read, read longer ago, or failed.
  bool _due(StoreApp app, Duration? maxAge) {
    if (maxAge == null) return true;
    if (_reads[app.key]?.phase == StoreAppReadPhase.failed) return true;
    final at = _apps[app.key]?.releases.checkedAt;
    return at == null || _now().difference(at) >= maxAge;
  }

  /// Forgets what [store] held of apps it no longer lists.
  void _dropUnlisted(StoreKind store, List<StoreApp> apps) {
    final keys = {for (final app in apps) app.key};
    bool gone(String key) => _storeOfKey(key) == store && !keys.contains(key);
    _apps.removeWhere((key, _) => gone(key));
    _icons.removeWhere((key, _) => gone(key));
    _reads.removeWhere((key, _) => gone(key));
  }

  /// Reads [app], and its icon beside it, telling each as it lands. Never
  /// throws. A read that gave nothing at all keeps the app's last numbers
  /// and marks it failed. Answers what changed since the app was last
  /// compared, or null when nothing did.
  Future<StoreAppChanges?> _readApp(
    StoreConsole console,
    StoreApp app,
    bool Function(StoreKind store) current,
  ) async {
    final key = app.key;
    if (!current(app.store)) return null;
    _reads[key] = const StoreAppRead.reading();
    _tell([StoreAppChanged(app: app, read: _reads[key])]);
    // In the same guarded zone and console as the snapshot, so it is closed
    // with them; bounded by [iconBudget].
    final icon = _iconDue(app)
        ? _refreshIcon(console, app, current).then((_) => true)
        : Future.value(false);
    StoreAppSnapshot? snapshot;
    String? failure;
    StoreAppChanges? changed;
    try {
      snapshot = await console.snapshot(app);
      failure = _failureOf(snapshot);
    } on Object catch (error) {
      failure =
          'The read stopped before the store answered (${error.runtimeType}).';
    }
    if (current(app.store)) {
      if (snapshot != null) changed = _compare(snapshot);
      final held = _apps[key];
      if (snapshot != null && (failure == null || held == null)) {
        _apps[key] = _withListingInstalls(snapshot.carriedFrom(held));
      }
      if (failure == null) {
        _reads.remove(key);
      } else {
        _reads[key] = StoreAppRead.failed(failure, _now());
      }
      _tell([
        StoreAppChanged(app: app, read: _reads[key], snapshot: _apps[key]),
      ]);
    }
    if (await icon && current(app.store)) {
      // The listing's install band may stand in for the reports' count.
      if (_apps[key] case final kept?) _apps[key] = _withListingInstalls(kept);
      _tell([
        StoreAppChanged(
          app: app,
          read: _reads[key],
          snapshot: _apps[key],
          icon: _icons[key],
        ),
      ]);
    }
    return changed;
  }

  /// What [snapshot] says changed since its app was last compared; the
  /// first read of an app keeps what it says and tells nothing.
  StoreAppChanges? _compare(StoreAppSnapshot snapshot) {
    final key = snapshot.app.key;
    final fresh = StoreDigest.of(snapshot);
    final before = _digests[key];
    _digests[key] = before == null ? fresh : before.mergedWith(fresh);
    if (before == null) return null;
    final changes = storeChanges(snapshot.app.store, before, fresh);
    if (changes.isEmpty) return null;
    return StoreAppChanges(
      app: snapshot.app,
      platform: storePlatform(snapshot),
      at: _now(),
      changes: changes,
    );
  }

  /// Keeps [found], files it, and tells every client once.
  Future<void> _announce(List<StoreAppChanges> found) async {
    final cutoff = _now().subtract(changeLogAge);
    _changeLog
      ..addAll(found)
      ..removeWhere((held) => held.at.isBefore(cutoff));
    if (_changeLog.length > changeLogLimit) {
      _changeLog.removeRange(0, _changeLog.length - changeLogLimit);
    }
    await _persistWatch();
    if (found.isEmpty) return;
    _log('stores: ${found.length} app(s) changed since their last read');
    _tell([StoreChangesNoticed(List.unmodifiable(found)), StoresChanged(view)]);
    onChanges?.call(found);
  }

  Future<StoresView> _seen(Set<String> appKeys) async {
    var moved = false;
    for (var i = 0; i < _changeLog.length; i++) {
      final held = _changeLog[i];
      if (held.seen || !appKeys.contains(held.app.key)) continue;
      _changeLog[i] = held.asSeen();
      moved = true;
    }
    onSeen?.call(appKeys);
    if (!moved) return view;
    await _persistWatch();
    final now = view;
    _tell([StoresChanged(now)]);
    return now;
  }

  Future<StoresView> _setEvery(Duration every) async {
    if (!StoreRefreshSchedule.choices.contains(every)) {
      throw DataRefused.invalid(
        'the stores are read on their own every 1, 3, 6 or 12 hours, or '
        'never; not every ${every.inMinutes} minutes',
      );
    }
    _everyChosen = every;
    await _persistWatch();
    _schedule.reschedule();
    final now = view;
    _tell([StoresChanged(now)]);
    return now;
  }

  /// What was compared and found for [store]'s apps goes with its
  /// credential: another account's apps are not news.
  void _forgetChanges(StoreKind store) {
    _digests.removeWhere((key, _) => _storeOfKey(key) == store);
    _changeLog.removeWhere((held) => held.app.store == store);
  }

  void _loadWatch() {
    final file = _watchFile;
    if (!file.existsSync()) return;
    try {
      final decoded = (jsonDecode(file.readAsStringSync()) as Map)
          .cast<String, Object?>();
      if (decoded['version'] != _watchVersion) {
        _log('stores: the kept changes are of another version; not read');
        return;
      }
      final every = decoded['everyMinutes'];
      if (every is int) {
        final chosen = Duration(minutes: every);
        if (StoreRefreshSchedule.choices.contains(chosen)) {
          _everyChosen = chosen;
        }
      }
      for (final MapEntry(:key, :value)
          in ((decoded['digests'] as Map?) ?? const {}).entries) {
        _digests[key as String] = StoreDigest.fromJson(
          (value as Map).cast<String, Object?>(),
        );
      }
      for (final held in (decoded['log'] as List?) ?? const []) {
        _changeLog.add(
          StoreAppChanges.fromJson((held as Map).cast<String, Object?>()),
        );
      }
    } on Object catch (error) {
      _digests.clear();
      _changeLog.clear();
      _log('stores: the kept changes were not read (${error.runtimeType})');
    }
  }

  Future<void> _persistWatch() {
    final contents = {
      'version': _watchVersion,
      'everyMinutes': ?_everyChosen?.inMinutes,
      'digests': {
        for (final MapEntry(:key, :value) in _digests.entries)
          key: value.toJson(),
      },
      'log': [for (final held in _changeLog) held.toJson()],
    };
    final done = _watchWrites.then((_) async {
      try {
        final directory = _watchFile.parent;
        if (!directory.existsSync()) directory.createSync(recursive: true);
        final temp = File('${_watchFile.path}.tmp');
        await temp.writeAsString(jsonEncode(contents), flush: true);
        await temp.rename(_watchFile.path);
      } on Object catch (error) {
        // Not kept: after a restart the next read compares with less.
        _log('stores: the changes were not kept (${error.runtimeType})');
      }
    });
    _watchWrites = done;
    return done;
  }

  /// Why [snapshot] holds nothing at all, or null when anything was read or
  /// every gap is the setup's rather than a fault.
  static String? _failureOf(StoreAppSnapshot snapshot) {
    final readings = <Reading<Object?>>[
      snapshot.releases,
      snapshot.reviews,
      snapshot.rating,
      snapshot.vitals,
      snapshot.downloads,
      ?snapshot.errorIssues,
      ?snapshot.allTimeInstalls,
    ];
    if (readings.any((reading) => reading is ReadingValue)) return null;
    for (final reading in readings) {
      if (reading case ReadingMissing(expected: false, :final message)) {
        return message;
      }
    }
    return null;
  }

  /// Reads one app again now, beside a refresh under way unless that refresh
  /// is about to read it anyway.
  Future<StoresView> _readOne(StoresRefreshApp request) async {
    final app =
        _held(request.store, request.id.trim()) ??
        (throw DataRefused.invalid(
          'no ${request.store.label} app "${request.id}" is among the apps '
          'read',
        ));
    final running = _running;
    final read = _reads[app.key];
    if (running != null &&
        read != null &&
        read.phase != StoreAppReadPhase.failed) {
      await running;
      return view;
    }
    if (_closed) return view;
    final generation = _gen(app.store);
    bool current(StoreKind store) => _gen(store) == generation;
    final console = _takeConsole();
    StoreAppChanges? changed;
    try {
      changed = await _guarded(() => _readApp(console, app, current));
    } finally {
      _releaseConsole();
      await _persist();
      await _announce([?changed]);
    }
    return view;
  }

  static StoreKind? _storeOfKey(String key) {
    final cut = key.indexOf(':');
    if (cut <= 0) return null;
    final name = key.substring(0, cut);
    for (final store in StoreKind.values) {
      if (store.name == name) return store;
    }
    return null;
  }

  /// Whether [app]'s icon is to be looked up now: never looked up, looked
  /// up over [iconMaxAge] ago, or its kept file gone — and no failed lookup
  /// within [iconRetry].
  bool _iconDue(StoreApp app) {
    final now = _now();
    final failed = _iconFailedAt[app.key];
    if (failed != null && now.difference(failed) < iconRetry) return false;
    final held = _icons[app.key];
    if (held == null) return true;
    if (now.difference(held.checkedAt) >= iconMaxAge) return true;
    // Kept by a server that read the page for the icon alone.
    if (app.store == StoreKind.googlePlay && !held.listingRead) return true;
    final path = held.path;
    return path != null && !File(path).existsSync();
  }

  /// [snapshot] with its all-time installs from the public listing's band
  /// when the store's own reports gave no count: a lower bound, said to be
  /// one, never a guess. The reports' reason stays as the band's note.
  StoreAppSnapshot _withListingInstalls(StoreAppSnapshot snapshot) {
    final reading = snapshot.allTimeInstalls;
    if (reading is! ReadingMissing<InstallTotal>) return snapshot;
    final listing = _icons[snapshot.app.key];
    if (listing == null || !listing.listingRead) return snapshot;
    final band = listing.installBand;
    final total = band == null
        ? null
        : InstallTotal.fromBand(band, note: reading.message);
    if (total != null) {
      return snapshot.withAllTimeInstalls(
        ReadingValue(total, listing.checkedAt),
      );
    }
    if (listing.url == null && reading.expected) {
      return snapshot.withAllTimeInstalls(
        ReadingMissing(
          reading.kind,
          'Not on the public store, so it shows no install count. '
          '${reading.message}',
          reading.checkedAt,
        ),
      );
    }
    return snapshot;
  }

  /// Looks [app]'s icon up and keeps it. Never throws, and never takes more
  /// than [iconBudget]; a failure keeps the icon held before.
  Future<void> _refreshIcon(
    StoreConsole console,
    StoreApp app,
    bool Function(StoreKind store) current,
  ) async {
    final Reading<StoreListing?> reading;
    try {
      reading = await console.listing(app).timeout(iconBudget);
    } on Object {
      _iconFailedAt[app.key] = _now();
      return;
    }
    if (!current(app.store)) return;
    final checkedAt = _now();
    final listingRead = app.store == StoreKind.googlePlay;
    final band = reading.valueOrNull?.installBand;
    switch (reading) {
      case ReadingMissing():
        _iconFailedAt[app.key] = checkedAt;
      case ReadingValue(value: null) ||
          ReadingValue(value: StoreListing(icon: null)):
        _iconFailedAt.remove(app.key);
        final old = _icons[app.key]?.path;
        _icons[app.key] = StoreAppIcon(
          checkedAt: checkedAt,
          installBand: band,
          listingRead: listingRead,
        );
        if (old != null) await _deleteQuietly(File(old));
      case ReadingValue(value: StoreListing(icon: final StoreIconImage image)):
        final file = File(
          p.join(
            _iconDirectory.path,
            '${app.store.name}-${_safeName(app.id)}${image.extension}',
          ),
        );
        try {
          if (!_iconDirectory.existsSync()) {
            _iconDirectory.createSync(recursive: true);
          }
          final temp = File('${file.path}.tmp');
          await temp.writeAsBytes(image.bytes, flush: true);
          await temp.rename(file.path);
        } on Object catch (error) {
          _iconFailedAt[app.key] = checkedAt;
          _log('stores: an icon was not kept (${error.runtimeType})');
          return;
        }
        _iconFailedAt.remove(app.key);
        final old = _icons[app.key]?.path;
        _icons[app.key] = StoreAppIcon(
          url: image.source.toString(),
          path: file.path,
          checkedAt: checkedAt,
          installBand: band,
          listingRead: listingRead,
        );
        // Another extension than before: the old file is no one's now.
        if (old != null && !p.equals(old, file.path)) {
          await _deleteQuietly(File(old));
        }
    }
  }

  /// [id] as a file name: a package name or a number already is one.
  static String _safeName(String id) =>
      id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on Object {
      // Left behind: a stale icon is overwritten by the next one.
    }
  }

  /// Forgets the icons of each store [gone] names, and deletes their files.
  Future<void> _forgetIcons(bool Function(StoreKind store) gone) async {
    final dropped = <String>[];
    _icons.removeWhere((key, icon) {
      final store = _storeOfKey(key);
      if (store == null || !gone(store)) return false;
      final path = icon.path;
      if (path != null) dropped.add(path);
      return true;
    });
    _iconFailedAt.removeWhere((key, _) {
      final store = _storeOfKey(key);
      return store == null || gone(store);
    });
    for (final path in dropped) {
      await _deleteQuietly(File(path));
    }
  }

  StoreConsole _consoleNow() {
    final held = _console;
    if (held != null) return held;
    final apple = _vault.apple;
    final play = _vault.play;
    return _console = StoreConsole([
      if (apple != null)
        _appleClient?.call(apple.key) ??
            AppleStoreClient(apple.key, salesLedger: _salesLedger),
      if (play != null)
        _playClient?.call(play.account) ??
            PlayStoreClient(
              play.account,
              installMonths: _installMonths,
              tokens: _playTokens,
            ),
    ], now: _now);
  }

  /// The console, held for a refresh or one app's read until
  /// [_releaseConsole].
  StoreConsole _takeConsole() {
    _consoleUsers++;
    return _consoleNow();
  }

  /// Closed once nothing reads with it, so no idle connection to a store is
  /// left open for minutes for a late answer to land on; the next read
  /// builds a new one with the credentials held then.
  void _releaseConsole() {
    _consoleUsers--;
    if (_consoleUsers > 0) return;
    for (final console in _retired) {
      console.close();
    }
    _retired.clear();
    _dropConsole();
  }

  /// Built again on the next read, with the credentials held then.
  void _dropConsole() {
    final old = _console;
    _console = null;
    if (old == null) return;
    if (_consoleUsers > 0) {
      _retired.add(old);
    } else {
      old.close();
    }
  }

  Future<StoresView> _setApple(StoreAppleSet request) async {
    final held = _vault.apple;
    final pem = request.privateKeyPem;
    if (pem == null && held == null) {
      throw const DataRefused.invalid(
        'this server holds no App Store Connect key yet; choose its .p8 file',
      );
    }
    final vendor = request.vendorNumber?.trim();
    final key = AppleApiKey(
      keyId: request.keyId.trim(),
      issuerId: request.issuerId.trim(),
      privateKeyPem: pem ?? held!.key.privateKeyPem,
      vendorNumber: vendor == null || vendor.isEmpty ? null : vendor,
    );
    final problem = key.problem;
    if (problem != null) throw DataRefused.invalid(problem);
    await _vault.setApple(
      HeldAppleKey(key, pem == null ? held!.importedAt : _now()),
    );
    return _credentialChanged(StoreKind.appStore, newKeyFile: pem != null);
  }

  Future<StoresView> _setPlay(StorePlaySet request) async {
    final held = _vault.play;
    final json = request.serviceAccountJson;
    if (json == null && held == null) {
      throw const DataRefused.invalid(
        'this server holds no Play service account yet; choose its JSON key '
        'file',
      );
    }
    final bucket = request.reportsBucket?.trim();
    final account = PlayAccount(
      serviceAccountJson: json ?? held!.account.serviceAccountJson,
      reportsBucket: bucket == null || bucket.isEmpty ? null : bucket,
      packageNames: {
        for (final name in request.packageNames)
          if (name.trim().isNotEmpty) name.trim(),
      }.toList(),
    );
    final problem = account.problem;
    if (problem != null) throw DataRefused.invalid(problem);
    await _vault.setPlay(
      HeldPlayAccount(account, json == null ? held!.importedAt : _now()),
    );
    return _credentialChanged(StoreKind.googlePlay, newKeyFile: json != null);
  }

  /// A new key file may be another account, so what the old one read goes
  /// with it; a changed vendor number, bucket or package list keeps it.
  Future<StoresView> _credentialChanged(
    StoreKind store, {
    required bool newKeyFile,
  }) async {
    _dropConsole();
    if (newKeyFile) {
      _generation[store] = _gen(store) + 1;
      _forgetReports(store);
      _stores.remove(store);
      _apps.removeWhere((_, kept) => kept.app.store == store);
      _reads.removeWhere((key, _) => _storeOfKey(key) == store);
      await _forgetIcons((kept) => kept == store);
      _forgetChanges(store);
      await _persistWatch();
      await _persist();
    }
    _tell([StoresChanged(view)]);
    if (newKeyFile) _refreshAfterRunning();
    return view;
  }

  final _generation = <StoreKind, int>{};

  /// Another key may be another account: what its reports said goes. A new
  /// object, not a cleared one, so a refresh still running on the old key
  /// writes into the one dropped.
  void _forgetReports(StoreKind store) {
    switch (store) {
      case StoreKind.appStore:
        _salesLedger = AppleSalesLedger();
      case StoreKind.googlePlay:
        _installMonths = PlayInstallMonths();
        _playTokens = PlayTokens();
    }
  }

  int _gen(StoreKind store) => _generation[store] ?? 0;

  /// A refresh already under way used the old credential, so this one waits
  /// for it rather than joining it.
  void _refreshAfterRunning() {
    final running = _running;
    final next = running == null ? refresh() : running.then((_) => refresh());
    unawaited(next.then<void>((_) {}, onError: (Object _) {}));
  }

  Future<StoresView> _remove(StoreKind store) async {
    await _vault.remove(store);
    _generation[store] = _gen(store) + 1;
    _forgetReports(store);
    _stores.remove(store);
    _apps.removeWhere((_, kept) => kept.app.store == store);
    _reads.removeWhere((key, _) => _storeOfKey(key) == store);
    await _forgetIcons((kept) => kept == store);
    _forgetChanges(store);
    _dropConsole();
    await _persist();
    await _persistWatch();
    _schedule.reschedule();
    final now = view;
    _tell([StoresChanged(now)]);
    return now;
  }

  /// What was read with a credential since removed is not kept.
  void _dropDisconnected() {
    final connected = _connected;
    _stores.removeWhere((store, _) => !connected.contains(store));
    _apps.removeWhere((_, kept) => !connected.contains(kept.app.store));
    _icons.removeWhere((key, _) => !connected.contains(_storeOfKey(key)));
    _reads.removeWhere((key, _) => !connected.contains(_storeOfKey(key)));
  }

  void _loadSnapshot() {
    final file = _snapshotFile;
    if (!file.existsSync()) return;
    try {
      final decoded = (jsonDecode(file.readAsStringSync()) as Map)
          .cast<String, Object?>();
      if (decoded['version'] != _snapshotVersion) return;
      final kept = StoresView.fromJson(
        (decoded['view']! as Map).cast<String, Object?>(),
      );
      _stores.addAll(kept.stores);
      for (final app in kept.apps) {
        _apps[app.app.key] = app;
      }
      _icons.addAll(kept.icons);
      _refreshedAt = kept.refreshedAt;
      // Caches: one unreadable is read again from the stores, not fatal.
      try {
        if (decoded['salesLedger'] case final Map ledger) {
          _salesLedger = AppleSalesLedger.fromJson(
            ledger.cast<String, Object?>(),
          );
        }
        if (decoded['installMonths'] case final Map months) {
          _installMonths = PlayInstallMonths.fromJson(
            months.cast<String, Object?>(),
          );
        }
      } on Object {
        _salesLedger = AppleSalesLedger();
        _installMonths = PlayInstallMonths();
      }
      _dropDisconnected();
    } on Object catch (error) {
      _stores.clear();
      _apps.clear();
      _icons.clear();
      _refreshedAt = null;
      _log('stores: the kept snapshot was not read (${error.runtimeType})');
    }
  }

  Future<void> _persist() {
    final shown = view;
    final kept = shown.toJson()
      ..remove('apple')
      ..remove('play')
      ..remove('links')
      ..remove('refreshing')
      ..remove('reads')
      ..remove('changes')
      ..remove('schedule');
    final done = _snapshotWrites.then(
      (_) => _writeSnapshot({
        'version': _snapshotVersion,
        'view': kept,
        'salesLedger': _salesLedger.toJson(),
        'installMonths': _installMonths.toJson(),
      }),
    );
    _snapshotWrites = done;
    return done;
  }

  Future<void> _writeSnapshot(Map<String, Object?> contents) async {
    try {
      final directory = _snapshotFile.parent;
      if (!directory.existsSync()) directory.createSync(recursive: true);
      final temp = File('${_snapshotFile.path}.tmp');
      await temp.writeAsString(jsonEncode(contents), flush: true);
      await temp.rename(_snapshotFile.path);
    } on Object catch (error) {
      // Not kept: the next start shows less until the stores are read again.
      _log('stores: the snapshot was not kept (${error.runtimeType})');
    }
  }

  /// [store]'s app [id] as held now — listed, or read before — or null when
  /// none is, or [store] is not connected.
  StoreApp? _held(StoreKind store, String id) {
    if (!_connected.contains(store)) return null;
    for (final app in [
      ...?_stores[store]?.valueOrNull,
      for (final kept in _apps.values) kept.app,
    ]) {
      if (app.store == store && app.id == id) return app;
    }
    return null;
  }

  Future<StoresView> _link(StoreAppsLink request) async {
    final appStoreId = request.appStoreId.trim();
    final packageName = request.packageName.trim();
    for (final (store, id) in [
      (StoreKind.appStore, appStoreId),
      (StoreKind.googlePlay, packageName),
    ]) {
      if (_held(store, id) == null) {
        throw DataRefused.invalid(
          _connected.contains(store)
              ? 'no ${store.label} app "$id" is among the apps read; refresh '
                    'the stores and try again'
              : '${store.label} is not connected',
        );
      }
    }
    final link = StoreAppLink(appStoreId: appStoreId, packageName: packageName);
    // An app is in one pair at most: a new one replaces what it was in.
    return _editLinks(
      (links) => links
        ..removeWhere(
          (old) =>
              old.appStoreId == appStoreId || old.packageName == packageName,
        )
        ..add(link),
    );
  }

  Future<StoresView> _unlink(StoreAppsUnlink request) {
    final link = StoreAppLink(
      appStoreId: request.appStoreId.trim(),
      packageName: request.packageName.trim(),
    );
    return _editLinks((links) {
      if (!links.remove(link)) {
        throw const DataRefused.invalid(
          'those two apps are not combined by hand',
        );
      }
      return links;
    });
  }

  /// Applies [edit] to a copy of the links, keeps the result, and only then
  /// holds it: a link not kept on disk is not shown as made. One edit at a
  /// time, so two at once cannot each lose the other's.
  Future<StoresView> _editLinks(
    List<StoreAppLink> Function(List<StoreAppLink> links) edit,
  ) {
    final done = _linkWrites.then((_) async {
      final next = edit([..._links]);
      await _writeLinks({
        'version': _linksVersion,
        'links': [for (final link in next) link.toJson()],
      });
      _links
        ..clear()
        ..addAll(next);
      final now = view;
      _tell([StoresChanged(now)]);
      return now;
    });
    _linkWrites = done.then<void>((_) {}, onError: (Object _) {});
    return done;
  }

  void _loadLinks() {
    final file = _linksFile;
    if (!file.existsSync()) return;
    try {
      final decoded = (jsonDecode(file.readAsStringSync()) as Map)
          .cast<String, Object?>();
      if (decoded['version'] != _linksVersion) {
        _log('stores: the combined apps are of another version; not read');
        return;
      }
      for (final link in (decoded['links'] as List?) ?? const []) {
        final read = StoreAppLink.fromJson(
          (link as Map).cast<String, Object?>(),
        );
        _links
          ..removeWhere(
            (old) =>
                old.appStoreId == read.appStoreId ||
                old.packageName == read.packageName,
          )
          ..add(read);
      }
    } on Object catch (error) {
      _links.clear();
      _log('stores: the combined apps were not read (${error.runtimeType})');
    }
  }

  /// Throws when not kept: unlike the snapshot, a lost link is the owner's
  /// work lost, so the request that made it says so.
  Future<void> _writeLinks(Map<String, Object?> contents) async {
    try {
      final directory = _linksFile.parent;
      if (!directory.existsSync()) directory.createSync(recursive: true);
      final temp = File('${_linksFile.path}.tmp');
      await temp.writeAsString(jsonEncode(contents), flush: true);
      await temp.rename(_linksFile.path);
    } on Object catch (error) {
      _log('stores: the combined apps were not kept (${error.runtimeType})');
      throw DataRefused.unavailable(
        'the server could not keep the combined apps (${error.runtimeType})',
      );
    }
  }
}
