import '../../../core/database/sqlite_row_reader.dart';
import 'dart:async';
import 'dart:isolate';

import 'package:karmashala_core/logging.dart';
import 'package:agent_cli/read.dart';

/// What to scan, in a form that crosses to a worker isolate.
class StoreScanRequest {
  const StoreScanRequest({
    required this.stores,
    this.workingDirectories,
    this.concurrency = kStoreScanConcurrency,
  });

  final List<CliStore> stores;

  /// The working directories to narrow each store to, where the store is
  /// addressable from one (`AgentStore.directoryNameFor`). Null reads
  /// everything, which is what "Detect CLI sessions" needs.
  final Set<String>? workingDirectories;

  final int concurrency;
}

/// One job's answer, handed back as that job finishes.
class StoreScanChunk {
  const StoreScanChunk({
    required this.agentId,
    required this.environmentId,
    required this.sessions,
    required this.isolate,
  });

  final String agentId;
  final String environmentId;
  final List<DetectedSession> sessions;

  /// Which isolate walked the store — [kStoreScanIsolateName] when the worker
  /// did. Reported rather than assumed, so the claim can be checked.
  final String isolate;
}

/// Reads CLI stores somewhere other than the isolate that draws: one worker for
/// a queue of per-CLI jobs — isolates do not make I/O-bound work parallel.
abstract interface class StoreScanRunner {
  Stream<StoreScanChunk> scan(StoreScanRequest request);
  Future<void> shutdown();
}

/// Runs the jobs on the calling isolate. What the app did before the worker,
/// what runs *inside* the worker, and the fallback when a host refuses one.
class InlineStoreScanRunner implements StoreScanRunner {
  InlineStoreScanRunner({CliDetectionService? detection})
    : _detection = detection ?? CliDetectionService(readRows: readSqliteRows);

  final CliDetectionService _detection;

  @override
  Stream<StoreScanChunk> scan(StoreScanRequest request) =>
      runStoreScanJobs(request, _detection);

  @override
  Future<void> shutdown() async {}
}

/// Debug name of the worker isolate, so a profile can tell a store walk apart
/// from the interface at a glance.
const String kStoreScanIsolateName = 'karmashala.store-scan';

/// The shared job queue, on its own long-lived isolate.
class IsolateStoreScanRunner implements StoreScanRunner {
  IsolateStoreScanRunner({AppLogger? logger})
    : _logger = logger ?? AppLogger.named('cli.storeScan');

  final AppLogger _logger;

  Isolate? _isolate;
  ReceivePort? _replies;
  SendPort? _jobs;
  Future<SendPort>? _starting;
  bool _isolatesUnavailable = false;

  int _nextId = 0;
  final Map<int, StreamController<StoreScanChunk>> _open = {};

  /// Whether the worker isolate exists yet. False until the first scan.
  bool get isWorkerRunning => _jobs != null;

  @override
  Stream<StoreScanChunk> scan(StoreScanRequest request) {
    final out = StreamController<StoreScanChunk>();
    out.onListen = () => unawaited(_start(request, out));
    return out.stream;
  }

  Future<void> _start(
    StoreScanRequest request,
    StreamController<StoreScanChunk> out,
  ) async {
    // No stores, no isolate: a host with no CLI installed never creates the
    // worker at all.
    if (request.stores.isEmpty) {
      await out.close();
      return;
    }
    if (_isolatesUnavailable) {
      await out.addStream(InlineStoreScanRunner().scan(request));
      await out.close();
      return;
    }
    final SendPort jobs;
    try {
      jobs = await _worker();
    } on Object catch (error) {
      _isolatesUnavailable = true;
      _logger.error(
        'Could not start the store-scan worker isolate; CLI stores will be '
        'read on the calling isolate from now on.',
        error,
      );
      await out.addStream(InlineStoreScanRunner().scan(request));
      await out.close();
      return;
    }
    final id = _nextId++;
    _open[id] = out;
    out.onCancel = () => _open.remove(id);
    jobs.send(_ScanRequest(id, request));
  }

  Future<SendPort> _worker() => _starting ??= _startWorker();

  Future<SendPort> _startWorker() async {
    final replies = ReceivePort('$kStoreScanIsolateName.replies');
    final ready = Completer<SendPort>();
    replies.listen((Object? message) => _onReply(message, ready));
    final Isolate isolate;
    try {
      isolate = await Isolate.spawn<SendPort>(
        _storeScanWorkerMain,
        replies.sendPort,
        debugName: kStoreScanIsolateName,
        onExit: replies.sendPort,
        onError: replies.sendPort,
      );
    } on Object {
      replies.close();
      _starting = null;
      rethrow;
    }
    _isolate = isolate;
    _replies = replies;
    final jobs = await ready.future;
    _jobs = jobs;
    return jobs;
  }

  void _onReply(Object? message, Completer<SendPort> ready) {
    if (message is SendPort) {
      if (!ready.isCompleted) ready.complete(message);
      return;
    }
    if (message is _ScanChunk) {
      _open[message.id]?.add(message.chunk);
      return;
    }
    if (message is _ScanDone) {
      unawaited(_open.remove(message.id)?.close());
      return;
    }
    if (message is _ScanFailed) {
      final out = _open.remove(message.id);
      out?.addError(message.error);
      unawaited(out?.close());
      return;
    }
    // `onError`: [description, stackTrace]. The worker catches what it can, so
    // this is a bug; the death behind it is handled by `onExit` below.
    if (message is List) {
      _logger.error('The store-scan worker isolate raised: ${message.first}');
      return;
    }
    _abandonWorker(ready);
  }

  void _abandonWorker(Completer<SendPort>? ready) {
    _jobs = null;
    _isolate = null;
    _starting = null;
    _replies?.close();
    _replies = null;
    final orphaned = _open.values.toList(growable: false);
    _open.clear();
    for (final out in orphaned) {
      out.addError(StateError('The store-scan worker isolate exited mid-scan'));
      unawaited(out.close());
    }
    if (ready != null && !ready.isCompleted) {
      ready.completeError(StateError('The store-scan worker isolate exited'));
    }
  }

  /// Kills the worker. The app never calls this; a test does so a suite leaves
  /// no live isolate behind.
  @override
  Future<void> shutdown() async {
    if (_isolate == null && _replies == null && _open.isEmpty) return;
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _abandonWorker(null);
  }
}

/// The app-wide store-scan worker. Lazy in two layers: Dart creates the object
/// on first read, the object creates its isolate on first scan.
final IsolateStoreScanRunner sharedStoreScanRunner = IsolateStoreScanRunner();

/// The queue itself: jobs in registry order, one at a time, a chunk each.
Stream<StoreScanChunk> runStoreScanJobs(
  StoreScanRequest request,
  CliDetectionService detection,
) async* {
  // Each job carries its store server, resolved on the main isolate and
  // carried in `CliStore`: a live `Process` cannot cross an isolate boundary,
  // and `CreateProcessW` costs ~1 s.
  for (final job in detection.jobsFor(request.stores)) {
    final sessions = await detection.runJob(
      job,
      workingDirectories: request.workingDirectories,
      slots: StoreScanSlots(concurrency: request.concurrency),
    );
    yield StoreScanChunk(
      agentId: job.agentId,
      environmentId: job.environmentId,
      sessions: sessions,
      isolate: Isolate.current.debugName ?? 'main',
    );
  }
}

void _storeScanWorkerMain(SendPort replies) {
  final jobs = ReceivePort(kStoreScanIsolateName);
  replies.send(jobs.sendPort);
  // One detection service for the worker's life, so the readers' caches — the
  // whole reason a second scan costs what changed — outlive a single request.
  final detection = CliDetectionService(readRows: readSqliteRows);
  jobs.listen((Object? message) {
    if (message is! _ScanRequest) return;
    unawaited(_serve(message, detection, replies));
  });
}

Future<void> _serve(
  _ScanRequest request,
  CliDetectionService detection,
  SendPort replies,
) async {
  try {
    await for (final chunk in runStoreScanJobs(request.request, detection)) {
      replies.send(_ScanChunk(request.id, chunk));
    }
    replies.send(_ScanDone(request.id));
  } on Object catch (error) {
    replies.send(_ScanFailed(request.id, StateError('$error')));
  }
}

class _ScanRequest {
  const _ScanRequest(this.id, this.request);
  final int id;
  final StoreScanRequest request;
}

class _ScanChunk {
  const _ScanChunk(this.id, this.chunk);
  final int id;
  final StoreScanChunk chunk;
}

class _ScanDone {
  const _ScanDone(this.id);
  final int id;
}

class _ScanFailed {
  const _ScanFailed(this.id, this.error);
  final int id;
  final Object error;
}
