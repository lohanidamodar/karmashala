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
       _tell = tell,
       _log = log ?? _silent,
       _now = clock ?? _utcNow,
       _appleClient = appleClient ?? AppleStoreClient.new,
       _playClient = playClient ?? PlayStoreClient.new {
    _loadSnapshot();
  }

  static const String snapshotDirectoryName = 'stores';
  static const String snapshotFileName = 'snapshot.json';
  static const int _snapshotVersion = 1;

  /// How many apps are read at once.
  static const int concurrency = 4;

  final ServerStoreVault _vault;
  final File _snapshotFile;
  final void Function(List<DataChange> changes) _tell;
  final void Function(String message) _log;
  final DateTime Function() _now;
  final StoreClient Function(AppleApiKey key) _appleClient;
  final StoreClient Function(PlayAccount account) _playClient;

  final _stores = <StoreKind, Reading<List<StoreApp>>>{};
  final _apps = <String, StoreAppSnapshot>{};
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
    if (maxAge != null && at != null && _now().difference(at) < maxAge) {
      return Future.value(view);
    }
    if (_connected.isEmpty || _closed) return Future.value(view);
    final done = Completer<StoresView>();
    _running = done.future;
    _run().then(done.complete, onError: done.completeError);
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

      var done = 0;
      final queue = apps.iterator;
      Future<void> worker() async {
        while (queue.moveNext()) {
          final app = queue.current;
          try {
            final snapshot = await console.snapshot(app);
            if (current(app.store)) _apps[app.key] = snapshot;
          } on Object {
            // A console closed under it: the app keeps what it had.
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
      _dropDisconnected();
      await _persist();
      _tell([StoresChanged(view)]);
    }
    return view;
  }

  StoreConsole _consoleNow() {
    final held = _console;
    if (held != null) return held;
    final apple = _vault.apple;
    final play = _vault.play;
    return _console = StoreConsole([
      if (apple != null) _appleClient(apple.key),
      if (play != null) _playClient(play.account),
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
      _stores.remove(store);
      _apps.removeWhere((_, kept) => kept.app.store == store);
      await _persist();
    }
    _tell([StoresChanged(view)]);
    if (newKeyFile) _refreshAfterRunning();
    return view;
  }

  final _generation = <StoreKind, int>{};

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
    _stores.remove(store);
    _apps.removeWhere((_, kept) => kept.app.store == store);
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
      _refreshedAt = kept.refreshedAt;
      _dropDisconnected();
    } on Object catch (error) {
      _stores.clear();
      _apps.clear();
      _refreshedAt = null;
      _log('stores: the kept snapshot was not read (${error.runtimeType})');
    }
  }

  Future<void> _persist() {
    final shown = view;
    final kept = shown.toJson()
      ..remove('apple')
      ..remove('play')
      ..remove('refreshing');
    final done = _snapshotWrites.then(
      (_) => _writeSnapshot({'version': _snapshotVersion, 'view': kept}),
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
}
