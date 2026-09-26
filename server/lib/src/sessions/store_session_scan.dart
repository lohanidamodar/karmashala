import 'dart:async';
import 'dart:isolate';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:sqlite3/sqlite3.dart';

/// Every conversation the agents' stores on this server's machines hold.
typedef StoreScan = Future<List<DetectedSession>> Function();

/// The server's [SqliteRowReader]: `package:sqlite3`, read-only, null on any
/// failure — a busy database is "not recorded", not an error to propagate.
Future<List<Map<String, Object?>>?> readStoreRows(
  String path,
  String sql,
) async {
  Database? db;
  try {
    db = sqlite3.open(path, mode: OpenMode.readOnly);
    return [
      for (final row in db.select(sql)) {...row},
    ];
  } on Object {
    return null;
  } finally {
    db?.close();
  }
}

/// Reads every agent store [stores] names, agent by agent in registry order,
/// through each adapter's own reader (`AgentStore.sessionReader`) — no agent
/// is named here. One reader per agent for this object's life, so the caches
/// behind them make a second scan cost what changed.
class StoreSessionReaders {
  StoreSessionReaders({this.registry = AgentRegistry.builtIn});

  final AgentRegistry registry;
  final Map<String, StoreSessionReader> _readers = {};

  Future<List<DetectedSession>> read(List<CliStore> stores) async {
    final found = <DetectedSession>[];
    for (final adapter in registry.adapters) {
      final store = adapter.store;
      if (store == null) continue;
      final reader = _readers[adapter.id] ??= store.sessionReader(
        readRows: readStoreRows,
      );
      for (final cliStore in stores) {
        final home = cliStore.homeFor(adapter.id);
        if (home == null) continue;
        try {
          found.addAll(
            await reader.read(
              home,
              cliStore.environmentId,
              slots: StoreScanSlots(concurrency: kStoreScanConcurrency),
            ),
          );
        } on Object {
          // One store we cannot read is that store saying nothing.
        }
      }
    }
    return found;
  }
}

/// Scans the agents' stores off the server's isolate: one long-lived worker,
/// so a walk over a WSL share never stalls a PTY or a protocol frame, and
/// the readers' caches outlive a single scan. Falls back to this isolate
/// when a worker cannot be started.
class StoreSessionScanner {
  StoreSessionScanner({
    required this.locate,
    bool useWorker = true,
    void Function(String message)? log,
  }) : _useWorker = useWorker,
       _log = log;

  /// Where each machine's stores are (`CliStoreLocator.locate` over the
  /// server's environments).
  final Future<List<CliStore>> Function() locate;
  final void Function(String message)? _log;
  bool _useWorker;

  final _inline = StoreSessionReaders();
  Isolate? _isolate;
  ReceivePort? _replies;
  Future<SendPort>? _worker;
  final Map<int, Completer<List<DetectedSession>>> _open = {};
  var _nextId = 0;

  /// Scans run, over this scanner's life.
  int scans = 0;

  /// One scan of every store. Throws when the stores could not be located.
  Future<List<DetectedSession>> scan() async {
    scans++;
    final stores = await locate();
    if (stores.isEmpty) return const [];
    if (!_useWorker) return _inline.read(stores);
    final SendPort jobs;
    try {
      jobs = await (_worker ??= _start());
    } on Object catch (error) {
      _useWorker = false;
      _log?.call(
        'session sync: no store-scan worker ($error); scanning on the main '
        'isolate',
      );
      return _inline.read(stores);
    }
    final id = _nextId++;
    final answer = _open[id] = Completer<List<DetectedSession>>();
    jobs.send((id, stores));
    return answer.future;
  }

  Future<SendPort> _start() async {
    final replies = ReceivePort('karmashala.session-sync.scan');
    _replies = replies;
    final ready = Completer<SendPort>();
    replies.listen((Object? message) {
      switch (message) {
        case final SendPort port:
          if (!ready.isCompleted) ready.complete(port);
        case (final int id, final List<DetectedSession> sessions):
          _open.remove(id)?.complete(sessions);
        case (final int id, final String error):
          _open.remove(id)?.completeError(StateError(error));
        default:
          // The worker died (`onExit`): fail what it held; the next scan
          // starts another.
          _abandon();
          if (!ready.isCompleted) {
            ready.completeError(StateError('the scan worker exited'));
          }
      }
    });
    _isolate = await Isolate.spawn<SendPort>(
      _scanWorkerMain,
      replies.sendPort,
      debugName: 'karmashala.session-sync.scan',
      onExit: replies.sendPort,
    );
    return ready.future;
  }

  void _abandon() {
    _worker = null;
    _isolate = null;
    _replies?.close();
    _replies = null;
    final orphaned = _open.values.toList();
    _open.clear();
    for (final answer in orphaned) {
      answer.completeError(StateError('the scan worker exited mid-scan'));
    }
  }

  void close() {
    _isolate?.kill(priority: Isolate.immediate);
    _abandon();
  }
}

void _scanWorkerMain(SendPort replies) {
  final jobs = ReceivePort('karmashala.session-sync.scan.jobs');
  replies.send(jobs.sendPort);
  final readers = StoreSessionReaders();
  jobs.listen((Object? message) async {
    if (message is! (int, List<CliStore>)) return;
    final (id, stores) = message;
    try {
      replies.send((id, await readers.read(stores)));
    } on Object catch (error) {
      replies.send((id, '$error'));
    }
  });
}

/// One store scan shared by everything one pass asks: adoption, launched
/// attribution and the title sync ask the disk the same question. Held as
/// the future, so a second asker waits on the one read.
class StoreScanPass {
  StoreScanPass(this._scan);

  final StoreScan _scan;
  Future<List<DetectedSession>>? _inFlight;

  Future<List<DetectedSession>> read() => _inFlight ??= _scan();

  /// Whether anything asked this pass.
  bool get scanned => _inFlight != null;
}
