import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:logging/logging.dart';
import './command_runner.dart';
import './process_spawn.dart';

/// Where a [CommandRunner] has its processes created.
///
/// One method, and the whole point of it is the answer to "on which isolate?".
/// `LocalCommandRunner` and `WslCommandRunner` describe *what* to run;
/// a [ProcessSpawner] owns *where the creation is charged*.
///
/// `SshCommandRunner` deliberately has none. It runs commands over a dartssh2
/// channel on an already-open socket and creates no process at all, on any
/// isolate — routing it through a spawning worker would add a hop and move
/// nothing.
abstract interface class ProcessSpawner {
  /// Runs [request] to completion, wherever this spawner creates processes.
  ///
  /// Throws whatever the creation threw — a [ProcessException] for a missing
  /// executable — so the runner that asked can name its own environment in the
  /// [CommandException] it raises.
  Future<CommandResult> run(CommandRequest request);

  /// Releases whatever this spawner holds. Idempotent.
  Future<void> shutdown();
}

/// Creates processes on the calling isolate — what the app did everywhere
/// before [IsolateProcessSpawner] existed.
///
/// Kept, and not only as a fallback: it is how a test asks for the *old*
/// behaviour, which is how the assertions in
/// `test/core/process/process_spawn_isolate_test.dart` can be shown to be about
/// something. It is also what runs inside the worker isolate, where "the
/// calling isolate" is the worker.
class InlineProcessSpawner implements ProcessSpawner {
  const InlineProcessSpawner();

  @override
  Future<CommandResult> run(CommandRequest request) =>
      spawnToCompletion(request);

  @override
  Future<void> shutdown() async {}
}

/// Debug name of the worker isolate, so a profile or a `--observe` session can
/// tell process creation apart from the interface at a glance.
const String kProcessWorkerIsolateName = 'karmashala.process-spawner';

/// Creates processes on one long-lived worker isolate.
///
/// **Why an isolate at all.** See `spawnToCompletion`: creating a process is
/// synchronous work charged to the isolate that asks, and the UI isolate is the
/// one that draws. A bound on how many probes are *in flight* — which
/// `kCheckoutProbeConcurrency` already is — cannot help, because every spawn
/// still passes through the asking isolate one at a time regardless of how many
/// are outstanding. The only fix is to ask from somewhere else.
///
/// **Why one long-lived worker rather than `Isolate.run` per command.**
/// `Isolate.run` spawns an isolate, runs one closure and tears it down; the
/// spawn and the teardown are themselves work charged to the caller, and the
/// Explorer's fan-out is thirty commands for one project expansion. That trades
/// thirty process creations on the UI isolate for thirty isolate creations on
/// it — a smaller bill in the same currency, and one that scales with the
/// number of commands instead of being paid once. One worker costs a single
/// `Isolate.spawn`, on first use, amortised over every command the app will
/// ever run.
///
/// **Why one worker and not a pool.** The worker is not blocked while a command
/// runs: it starts the process and awaits its exit, so it is free to serve the
/// next message immediately. Only the *creations* serialise on the worker's
/// thread — and they serialised on the UI thread before, so nothing got slower;
/// what changed is which thread pays. A pool would overlap the creations too,
/// but sizing one is a measurement nobody has taken yet, and it would be
/// spending complexity on wall-clock rather than on the stall that was
/// reported.
///
/// **Created on first use, not at start-up.** Start-up is under scrutiny — it
/// was 1.91 s and is being cut — so this adds nothing to it that is not paid
/// for. Today the first command is environment discovery in `main()`, so the
/// one `Isolate.spawn` does land on the launch path; it costs a few
/// milliseconds of thread-local work and immediately removes a `wsl.exe`
/// creation measured at 208-439 ms from that same thread. On a host with no
/// WSL, or a launch that runs no command, the worker is never created at all,
/// which an eager start-up spawn could not manage.
///
/// **Ordering.** Messages arrive at the worker in send order and its handler
/// runs each one's synchronous prefix before yielding, so process *creations*
/// happen in the order the app asked for them. Completion order is whatever the
/// processes do — exactly as it was when each caller had its own `Process.run`.
///
/// **Failure.** The worker catches everything and replies with it, so a
/// [ProcessException] still reaches the runner that asked and still becomes the
/// same [CommandException] as before. If the worker dies anyway, every
/// outstanding command completes with a [CommandException] rather than hanging,
/// and the next command starts a fresh worker. If `Isolate.spawn` itself is
/// refused, the spawner degrades to [InlineProcessSpawner] and says so in the
/// log: a laggy app is better than one that cannot run a command.
///
/// **Platform.** There is no host check anywhere in here. `CreateProcessW` is
/// dearer than `posix_spawn`, but a spawn on the UI isolate is a spawn on the
/// UI isolate, so macOS and Linux take the same path for the same reason.
class IsolateProcessSpawner implements ProcessSpawner {
  IsolateProcessSpawner({Logger? logger})
    : _logger = logger ?? Logger('process.spawner');

  final Logger _logger;

  Isolate? _isolate;
  ReceivePort? _replies;
  SendPort? _jobs;
  Future<SendPort>? _starting;

  /// Set once `Isolate.spawn` has been refused. Permanent, because a host that
  /// cannot make an isolate will not start being able to.
  bool _isolatesUnavailable = false;

  int _nextId = 0;
  final Map<int, Completer<CommandResult>> _pending =
      <int, Completer<CommandResult>>{};

  /// Whether the worker isolate exists yet.
  ///
  /// `false` until the first [run], which is the lazy-creation property stated
  /// above, and the assertion that an SSH command has not quietly started one.
  bool get isWorkerRunning => _jobs != null;

  /// Commands handed to the worker and not yet answered.
  int get pendingCommands => _pending.length;

  @override
  Future<CommandResult> run(CommandRequest request) async {
    if (_isolatesUnavailable) return spawnToCompletion(request);

    final SendPort jobs;
    try {
      jobs = await _worker();
    } on _IsolateSpawnRefused catch (failure) {
      _isolatesUnavailable = true;
      _logger.severe(
        'Could not start the process worker isolate; commands will be created '
        'on the calling isolate from now on.',
        failure.cause,
      );
      return spawnToCompletion(request);
    }

    final id = _nextId++;
    final completer = Completer<CommandResult>();
    _pending[id] = completer;
    jobs.send(_SpawnJob(id, request));
    return completer.future;
  }

  Future<SendPort> _worker() => _starting ??= _startWorker();

  Future<SendPort> _startWorker() async {
    final replies = ReceivePort('$kProcessWorkerIsolateName.replies');
    final ready = Completer<SendPort>();
    replies.listen((Object? message) => _onReply(message, ready));

    final Isolate isolate;
    try {
      isolate = await Isolate.spawn<SendPort>(
        _processWorkerMain,
        replies.sendPort,
        debugName: kProcessWorkerIsolateName,
        // Both are delivered to the same port the replies use, so one listener
        // sees a result, a crash and a death — and no outstanding command can
        // be left waiting for a worker that is gone.
        onExit: replies.sendPort,
        onError: replies.sendPort,
      );
    } on Object catch (error) {
      replies.close();
      _starting = null;
      throw _IsolateSpawnRefused(error);
    }

    _isolate = isolate;
    _replies = replies;
    final jobs = await ready.future;
    _jobs = jobs;
    return jobs;
  }

  void _onReply(Object? message, Completer<SendPort> ready) {
    // The worker's own port, sent once as its handshake.
    if (message is SendPort) {
      if (!ready.isCompleted) ready.complete(message);
      return;
    }
    if (message is _SpawnDone) {
      _pending.remove(message.id)?.complete(message.result);
      return;
    }
    if (message is _SpawnFailed) {
      _pending.remove(message.id)?.completeError(message.error);
      return;
    }
    // `onError`: a two-element [description, stackTrace] of strings. The worker
    // catches everything it can, so this is a bug rather than a failed command;
    // it is logged, and the death that follows is handled by `onExit` below.
    if (message is List) {
      _logger.severe('The process worker isolate raised: ${message.first}');
      return;
    }
    // `onExit`: null.
    _abandonWorker(
      ready,
      CommandException(
        'The process worker isolate exited before the command finished',
      ),
    );
  }

  /// Forgets the worker and fails everything that was waiting on it.
  ///
  /// Nothing is retried here: a command that was already running may have had
  /// its process created, and running it a second time is not this layer's
  /// decision to make. The *next* command starts a fresh worker.
  void _abandonWorker(Completer<SendPort>? ready, CommandException failure) {
    _jobs = null;
    _isolate = null;
    _starting = null;
    _replies?.close();
    _replies = null;

    final orphaned = _pending.values.toList(growable: false);
    _pending.clear();
    for (final waiter in orphaned) {
      if (!waiter.isCompleted) waiter.completeError(failure);
    }
    if (ready != null && !ready.isCompleted) ready.completeError(failure);
  }

  /// Kills the worker, if there is one, and fails anything still outstanding.
  ///
  /// The app never calls this: quitting reclaims the isolate, and a shutdown
  /// step that waits for it would spend the shutdown budget on nothing. Tests
  /// call it so a suite does not leave a live isolate behind.
  @override
  Future<void> shutdown() async {
    if (_isolate == null && _replies == null && _pending.isEmpty) return;
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _abandonWorker(
      null,
      CommandException('The process worker isolate was shut down'),
    );
  }
}

/// The app-wide worker every `LocalCommandRunner` and `WslCommandRunner` uses
/// unless it was handed one of its own.
///
/// A library-level lazy `final` rather than a Riverpod provider because
/// `const LocalCommandRunner()` is composed in three places, one of them
/// `main()` before any container exists — and because there is exactly one
/// right answer for the whole process, not one per scope. It is never
/// reassigned, and the injectable constructor parameter on each runner is the
/// seam a test uses instead of mutating it.
///
/// Lazy in two layers: Dart creates the object on first read, and the object
/// creates its isolate on first command.
final IsolateProcessSpawner sharedProcessSpawner = IsolateProcessSpawner();

/// Raised inside [IsolateProcessSpawner] when the host refuses an isolate.
/// Private, and never seen by a caller: it only tells [IsolateProcessSpawner.run]
/// to fall back rather than fail.
class _IsolateSpawnRefused implements Exception {
  _IsolateSpawnRefused(this.cause);
  final Object cause;
}

/// One command handed to the worker, tagged so its answer can be found again.
///
/// Plain data, which is what lets it cross: a string, a list of strings, a bool
/// and an `EnvironmentPath` that keeps its environment id all the way to the
/// `Process.run` call.
class _SpawnJob {
  const _SpawnJob(this.id, this.request);
  final int id;
  final CommandRequest request;
}

class _SpawnDone {
  const _SpawnDone(this.id, this.result);
  final int id;
  final CommandResult result;
}

class _SpawnFailed {
  const _SpawnFailed(this.id, this.error);
  final int id;

  /// The [ProcessException] the creation threw, sent as itself so the runner
  /// that asked builds exactly the [CommandException] it always built — or a
  /// [CommandException] already, for the failures that are not a process's.
  final Object error;
}

/// The worker isolate's body.
///
/// It listens rather than `await for`ing: a `await for` would not serve the
/// next command until the previous process had *exited*, turning a worker that
/// merely serialises creations into one that serialises whole commands.
void _processWorkerMain(SendPort replies) {
  final jobs = ReceivePort(kProcessWorkerIsolateName);
  replies.send(jobs.sendPort);
  jobs.listen((Object? message) {
    if (message is! _SpawnJob) return;
    // Deliberately not awaited: the synchronous prefix of `_serve` — the
    // process creation — runs here, in message order, and the wait for the
    // exit does not hold the next command up.
    unawaited(_serve(message, replies));
  });
}

Future<void> _serve(_SpawnJob job, SendPort replies) async {
  try {
    replies.send(_SpawnDone(job.id, await spawnToCompletion(job.request)));
  } on ProcessException catch (error) {
    replies.send(_SpawnFailed(job.id, error));
  } on Object catch (error) {
    // Anything else: reported as a CommandException rather than sent raw,
    // because an arbitrary error object may not survive the boundary and a
    // command that vanished is worse than one that says why it failed.
    replies.send(
      _SpawnFailed(
        job.id,
        CommandException(
          'Failed to run "${job.request.executable}" on the process worker '
          'isolate',
          cause: '$error',
        ),
      ),
    );
  }
}
