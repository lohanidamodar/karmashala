import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_mcp/access.dart'
    show HandshakePermissions, SystemHandshakePermissions;
import 'package:path/path.dart' as p;
import 'package:store_console/store_console.dart';
import 'package:store_console_apple/store_console_apple.dart';
import 'package:store_console_play/store_console_play.dart';

import 'server_store_vault.dart';
import 'store_desk.dart';

/// The app stores as this server reads them, with the credentials in
/// [ServerStoreVault]. It talks to a store only when asked; nothing polls.
class ServerStoreDesk implements StoreDesk, StoreWork {
  ServerStoreDesk({
    required String dataDirectory,
    required void Function(List<DataChange> changes) tell,
    void Function(String message)? log,
    DateTime Function()? clock,
    HandshakePermissions permissions = const SystemHandshakePermissions(),
    StoreClient Function(AppleApiKey key)? appleClient,
    StoreClient Function(PlayAccount account)? playClient,
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
       _tell = tell,
       _log = log ?? _silent,
       _now = clock ?? _utcNow,
       _appleClient = appleClient,
       _playClient = playClient {
    _loadSnapshot();
    _loadLinks();
  }

  static const String snapshotDirectoryName = 'stores';
  static const String snapshotFileName = 'snapshot.json';
  static const int _snapshotVersion = 1;

  /// The apps combined by hand. Beside the snapshot but not in it: the
  /// snapshot is a cache, dropped when unreadable or of another version;
  /// these are the owner's word, and outlive a credential being replaced.
  static const String linksFileName = 'links.json';
  static const int _linksVersion = 1;

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
  final void Function(List<DataChange> changes) _tell;
  final void Function(String message) _log;
  final DateTime Function() _now;
  final StoreClient Function(AppleApiKey key)? _appleClient;
  final StoreClient Function(PlayAccount account)? _playClient;

  /// The finished report periods the all-time counts are made of, read once
  /// and kept with the snapshot: a console lasts one refresh, these outlive
  /// it.
  var _salesLedger = AppleSalesLedger();
  var _installMonths = PlayInstallMonths();

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

  /// Consoles replaced while a refresh was using them; closed when it ends.
  final _retired = <StoreConsole>[];

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
    );
  }

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
    // In a guarded zone: Dart's HttpClient raises some failures with no
    // request to fail — Google answering on an idle pooled connection
    // ("unsolicited response without request", seen 2026-10-01) — as
    // uncaught errors, and an uncaught error ends the server. Here one is
    // logged and the refresh's own calls fail or finish as they would.
    runZonedGuarded(
      () => _run().then(done.complete, onError: done.completeError),
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
    final StoreAppleSet r => await _setApple(r),
    final StorePlaySet r => await _setPlay(r),
    StoreCredentialRemove(:final store) => await _remove(store),
    final StoreAppsLink r => await _link(r),
    final StoreAppsUnlink r => await _unlink(r),
    _ => throw DataRefused.invalid('${request.kind} is not a store request'),
  };

  void close() {
    _closed = true;
    _console?.close();
    _console = null;
    for (final console in _retired) {
      console.close();
    }
    _retired.clear();
  }

  Future<StoresView> _run() async {
    _tell([StoresChanged(view)]);
    // What a store said with a key since replaced is not written back.
    final started = {for (final store in StoreKind.values) store: _gen(store)};
    bool current(StoreKind store) => _gen(store) == started[store];
    try {
      final console = _consoleNow();
      final listed = await console.listApps();
      final answered = {
        for (final reading in listed)
          if (reading.apps is ReadingValue) reading.store,
      };
      final apps = [for (final reading in listed) ...?reading.apps.valueOrNull];
      for (final reading in listed) {
        if (current(reading.store)) _stores[reading.store] = reading.apps;
      }
      // An app a store no longer lists goes; one from a store that did not
      // answer stays as last read.
      _apps.removeWhere(
        (_, kept) =>
            current(kept.app.store) &&
            answered.contains(kept.app.store) &&
            !apps.contains(kept.app),
      );
      final listedKeys = {for (final app in apps) app.key};
      _icons.removeWhere((key, _) {
        final store = _storeOfKey(key);
        return store != null &&
            current(store) &&
            answered.contains(store) &&
            !listedKeys.contains(key);
      });

      var done = 0;
      final queue = apps.iterator;
      Future<void> worker() async {
        while (queue.moveNext()) {
          final app = queue.current;
          StoreAppSnapshot? snapshot;
          try {
            snapshot = await console.snapshot(app);
          } on Object {
            // A console closed under it: the app keeps what it had.
          }
          // In the same guarded zone and the same console as the snapshot,
          // so it is closed with them; bounded by the workers and a budget.
          if (current(app.store) && _iconDue(app)) {
            await _refreshIcon(console, app, current);
          }
          if (snapshot != null && current(app.store)) {
            _apps[app.key] = _withListingInstalls(
              snapshot.carriedFrom(_apps[app.key]),
            );
          }
          done++;
          _tell([StoresProgress(done: done, total: apps.length)]);
        }
      }

      await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);
      if (answered.isNotEmpty) _refreshedAt = _now();
      _log(
        'stores: read ${apps.length} app(s); '
        '${answered.length} of ${listed.length} store(s) answered',
      );
    } on Object catch (error) {
      _log('stores: the refresh stopped (${error.runtimeType})');
    } finally {
      _running = null;
      for (final console in _retired) {
        console.close();
      }
      _retired.clear();
      // Closed after every refresh, so no idle connection to a store is left
      // open for minutes for a late answer to land on; the next refresh
      // builds a new console with the credentials held then.
      _dropConsole();
      _dropDisconnected();
      await _persist();
      _tell([StoresChanged(view)]);
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
            PlayStoreClient(play.account, installMonths: _installMonths),
    ], now: _now);
  }

  /// Built again on the next refresh, with the credentials held then.
  void _dropConsole() {
    final old = _console;
    _console = null;
    if (old == null) return;
    if (_running != null) {
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
      await _forgetIcons((kept) => kept == store);
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
    await _forgetIcons((kept) => kept == store);
    _dropConsole();
    await _persist();
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
      ..remove('refreshing');
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
