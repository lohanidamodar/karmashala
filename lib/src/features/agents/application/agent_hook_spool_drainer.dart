import 'dart:async';
import 'dart:io';

import 'package:agent_cli/process.dart';
import '../data/agent_hook_spool.dart';

/// One environment's spool directory, as this app can name it.
class AgentHookSpoolSource {
  const AgentHookSpoolSource({
    required this.environmentId,
    required this.directory,
    this.wslDistribution,
  });

  final String environmentId;

  /// Where the payloads land, in **this app's** spelling — a
  /// `\\wsl.localhost\<distro>\home\<user>\.claude\…` UNC path for a WSL store.
  final Directory directory;

  /// The distribution this store lives in, when it lives in one. Read only to
  /// decide whether listing the directory is worth it at all.
  final String? wslDistribution;
}

/// Which WSL distributions are running, without starting any that are not.
///
/// `wsl.exe -l --running -q` is answered by the service on the Windows side, so
/// it cannot wake a distribution — the entire reason it is here. Measured at
/// 188 ms, all of which used to be the UI isolate's: creating a process is
/// synchronous work charged to whoever asks, so this goes through
/// [sharedProcessSpawner]'s worker isolate like the command runners do.
Future<Set<String>> wslRunningDistributions() async {
  try {
    final result = await sharedProcessSpawner.run(
      const CommandRequest(
        executable: 'wsl.exe',
        arguments: ['-l', '--running', '-q'],
      ),
    );
    if (result.exitCode != 0) return const {};
    return parseWslDistributions(result.stdout).toSet();
  } on Object {
    return const {};
  }
}

/// How the drainer arms its polling loop, and how it takes it down: the shape
/// `ScrollbackAutosave` established, a pair of functions with real-`Timer`
/// defaults, so the app runs on a clock and a test steps one.
typedef PeriodicSchedule =
    Object Function(Duration interval, void Function() tick);
typedef CancelPeriodic = void Function(Object handle);

/// Polls the spool directories WSL agents write their hook payloads into.
///
/// **A poll and not a push** because `Directory.watch` over `\\wsl.localhost`
/// returns a subscription that never yields an event — measured — while a
/// listing of that share costs 0.68 ms warm. Every operation here is
/// asynchronous: that cost belongs to the distribution and has no ceiling, and a
/// `listSync` put the whole wait on the UI isolate every [interval].
///
/// **It will not wake a distribution the user shut down.** The share is served
/// by a plan9 daemon *inside* the distribution, so listing it starts a stopped
/// one; the running set is refreshed every [runningRefresh] by a query that
/// starts nothing, and a distribution missing from it is skipped. Nothing is
/// lost — one with no processes has no agent to fire a hook, and its payloads
/// are still there when it comes back. Fails **open**: a failed running-set
/// query is read as "all of them".
class AgentHookSpoolDrainer {
  AgentHookSpoolDrainer({
    required this.onEvent,
    this.spool = const AgentHookSpool(),
    this.interval = const Duration(milliseconds: 400),
    this.runningRefresh = const Duration(seconds: 15),
    this.maxPerTick = 64,
    this.runningDistributions = wslRunningDistributions,
    this.schedule = _defaultSchedule,
    this.cancelSchedule = _defaultCancel,
  });

  /// What one drained payload does. Wired to `applyAgentHookCallback` in the
  /// provider; injected here so the loop can be driven with no container.
  final void Function(AgentHookSpoolEvent event) onEvent;

  final AgentHookSpool spool;
  final Duration interval;
  final Duration runningRefresh;

  /// How many payloads one tick will take from one directory. A launch that
  /// finds a backlog from an unclean exit spreads it over ticks rather than
  /// holding the isolate.
  final int maxPerTick;

  /// See the class doc. Injected so a test never spawns `wsl.exe`.
  final Future<Set<String>> Function() runningDistributions;

  /// How the loop is armed, and how it is taken down. Injected the way
  /// `ScrollbackAutosave`'s `DelayedSchedule` is: a real `Timer` makes a test
  /// **wait**, and a test that waits measures this machine's scheduler rather
  /// than this class.
  final PeriodicSchedule schedule;
  final CancelPeriodic cancelSchedule;

  Object? _handle;
  List<AgentHookSpoolSource> _sources = const [];
  Set<String>? _running;
  DateTime? _runningAt;
  bool _draining = false;
  bool _disposed = false;
  Future<void>? _inFlight;

  /// The drain the last tick started, or a completed future when none has run.
  /// For the one caller that has to know when a tick it *fired* has finished: a
  /// test stepping the loop through [schedule]. The app never reads it.
  Future<void> get settled => _inFlight ?? Future<void>.value();

  /// The directories being polled, or none. Exposed for the settings surface
  /// and for tests; the app has no reason to read it.
  List<AgentHookSpoolSource> get sources => List.unmodifiable(_sources);

  /// Starts polling [sources], replacing whatever was being polled before. An
  /// empty list stops the timer rather than running it over nothing, which is
  /// the usual case: a machine with no WSL, or one entirely on HTTP.
  void watch(List<AgentHookSpoolSource> sources) {
    // A disposed drainer stays disposed: `dispose` is what shutdown calls, and
    // a late `watch` must not put the loop back on a share that is going away.
    if (_disposed) return;
    _sources = List.unmodifiable(sources);
    _cancel();
    if (_sources.isEmpty) return;
    _handle = schedule(interval, () {
      final drain = drainOnce();
      _inFlight = drain;
      unawaited(drain);
    });
  }

  /// One pass over every source. Public so a test can step the loop. Re-entrant
  /// calls are dropped rather than queued: the files a waiting tick has not read
  /// yet will still be there.
  Future<void> drainOnce() async {
    if (_draining || _disposed) return;
    _draining = true;
    try {
      final running = await _runningSet();
      // **Checked between sources, not once at the top.** `dispose` cancels the
      // timer, which ends the *next* tick; a drain already awaiting a
      // distribution would go on deleting payloads under directories nobody owns
      // any more — somebody's store home after a quit, or the temp directory a
      // test's `tearDown` is already walking.
      for (final source in _sources) {
        if (_disposed) return;
        final distribution = source.wslDistribution;
        if (distribution != null &&
            running != null &&
            !running.contains(distribution)) {
          continue;
        }
        final events = await spool.drain(
          source.directory,
          limit: maxPerTick,
        );
        for (final event in events) {
          onEvent(event);
        }
      }
    } finally {
      _draining = false;
    }
  }

  /// The running distributions, refreshed at most every [runningRefresh], or
  /// `null` when the answer is not to be trusted and everything should be
  /// polled.
  Future<Set<String>?> _runningSet() async {
    final needsDistribution = _sources.any((s) => s.wslDistribution != null);
    if (!needsDistribution) return null;
    final at = _runningAt;
    if (at != null && DateTime.now().difference(at) < runningRefresh) {
      return _running;
    }
    final running = await runningDistributions();
    _runningAt = DateTime.now();
    // An empty answer is the fail-open case: `wsl.exe` missing, refusing, or
    // answering something this could not read. Polling a stopped distribution
    // costs a wake-up; not polling a running one costs every status in it.
    _running = running.isEmpty ? null : running;
    return _running;
  }

  /// Stops the loop, and stops the drain already in flight from touching the
  /// filesystem again. Cancelling the timer alone only ended the next tick.
  void dispose() {
    _disposed = true;
    _cancel();
    _sources = const [];
  }

  void _cancel() {
    if (_handle case final handle?) cancelSchedule(handle);
    _handle = null;
  }

  static Object _defaultSchedule(Duration interval, void Function() tick) =>
      Timer.periodic(interval, (_) => tick());

  static void _defaultCancel(Object handle) => (handle as Timer).cancel();
}
