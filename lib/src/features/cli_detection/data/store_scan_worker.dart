import 'dart:async';
import 'dart:isolate';

import 'package:karmashala_core/logging.dart';
import '../../agents/domain/agent_descriptor.dart';
import '../application/cli_detection_service.dart';
import '../domain/detected_session.dart';
import 'store_scan_slots.dart';

/// What to scan, in a form that crosses to a worker isolate.
class StoreScanRequest {
  const StoreScanRequest({
    required this.stores,
    this.claudeDirectories,
    this.concurrency = kStoreScanConcurrency,
  });

  final List<CliStore> stores;

  /// Narrows the Claude jobs — see `ClaudeStoreReader.read`. Null reads
  /// everything, which is what "Detect CLI sessions" needs.
  final Set<String>? claudeDirectories;

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
  /// did. Reported rather than assumed: "off the UI isolate" is the whole claim
  /// and a claim nobody can read is one nobody can check.
  final String isolate;
}

/// Reads CLI stores somewhere other than the isolate that draws.
///
/// Runs [StoreScanRequest]s as a **queue of per-CLI jobs**, Claude then Codex
/// then Antigravity, one at a time, streaming each job's sessions back as it
/// finishes.
///
/// **One worker, not one per CLI.** Isolates do not make I/O-bound work
/// parallel — Dart's async I/O already interleaves, and three isolates walking
/// three stores contend on the same 9p boundary and finish no sooner, for three
/// spawn costs. The isolate is here to keep several thousand stream events off
/// the isolate that paints, which one worker does as well as three. It is also
/// the structure that scales: the next agent is one more descriptor and one
/// more job, not a new isolate with a new lifecycle.
///
/// Everything else follows `IsolateProcessSpawner`, which is the house pattern:
/// created on first use so a launch that never scans pays nothing, plain data
/// both ways, and a fall back to running inline when the host refuses an
/// isolate — a laggy scan beats no sessions.
abstract interface class StoreScanRunner {
  Stream<StoreScanChunk> scan(StoreScanRequest request);
  Future<void> shutdown();
}

/// Runs the jobs on the calling isolate. What the app did before the worker,
/// what runs *inside* the worker, and the fallback when a host refuses one.
class InlineStoreScanRunner implements StoreScanRunner {
  InlineStoreScanRunner({CliDetectionService? detection})
    : _detection = detection ?? CliDetectionService();

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
    // No stores, no isolate. A host with no CLI installed never creates the
    // worker at all, the way `IsolateProcessSpawner` never creates its own on a
    // launch that runs no command.
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
      out.addError(
        StateError('The store-scan worker isolate exited mid-scan'),
      );
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

/// The app-wide store-scan worker. Lazy in two layers, like
/// `sharedProcessSpawner`: Dart creates the object on first read, the object
/// creates its isolate on first scan.
final IsolateStoreScanRunner sharedStoreScanRunner = IsolateStoreScanRunner();

/// The queue itself: jobs in registry order, one at a time, a chunk each.
Stream<StoreScanChunk> runStoreScanJobs(
  StoreScanRequest request,
  CliDetectionService detection,
) async* {
  // Resolved on the main isolate and carried in `CliStore`: the worker builds
  // the runner and spawns Codex itself, because a live `Process` cannot cross
  // an isolate boundary and a ~1 s `CreateProcessW` must not be on the isolate
  // that draws.
  final appServers = CliDetectionService.codexAppServersIn(request.stores);
  for (final job in detection.jobsFor(request.stores)) {
    final sessions = await detection.runJob(
      job,
      directories: job.format == AgentStoreFormat.claudeJsonl
          ? request.claudeDirectories
          : null,
      slots: StoreScanSlots(concurrency: request.concurrency),
      appServer: appServers[job.environmentId],
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
  final detection = CliDetectionService();
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
