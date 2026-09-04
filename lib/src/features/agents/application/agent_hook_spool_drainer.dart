import 'dart:async';
import 'dart:io';

import '../../../core/process/wsl_distributions.dart';
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
  /// decide whether it is worth listing the directory at all: see
  /// [AgentHookSpoolDrainer.runningDistributions].
  final String? wslDistribution;
}

/// Which WSL distributions are running, without starting any that are not.
///
/// `wsl.exe -l --running -q` is answered by the service on the Windows side,
/// so it cannot wake a distribution — which is the entire reason it is here.
/// Measured at 188 ms on the owner's machine.
Future<Set<String>> wslRunningDistributions() async {
  try {
    final result = await Process.run('wsl.exe', ['-l', '--running', '-q']);
    if (result.exitCode != 0) return const {};
    return parseWslDistributions('${result.stdout}').toSet();
  } on Object {
    return const {};
  }
}

/// Polls the spool directories WSL agents write their hook payloads into.
///
/// **Why a poll and not a push.** A WSL store is reached over
/// `\\wsl.localhost`, and `Directory.watch` on that share returns a
/// subscription that never yields an event — measured, not assumed. The
/// alternative push would be a long-lived `wsl.exe` relay printing events on
/// stdout, which costs a held process per distribution and a framing format to
/// buy back a latency nobody can feel: a listing of that share costs **0.68 ms
/// warm**, so a tick every [interval] is a rounding error next to the
/// five-second status poll it feeds.
///
/// **A rounding error only while the share answers.** That cost is the
/// distribution's to pay, not this app's, and it has no ceiling — so every
/// operation the drain performs is asynchronous rather than synchronous. A
/// `listSync` here used to put the whole wait on the isolate, four hundred
/// milliseconds apart, for as long as the distribution took; `AgentHookSpool`
/// carries the measurements and `core/util/file_picking.dart` carries what an
/// occupied isolate does to a native file dialog that is being created at the
/// same moment.
///
/// **It will not wake a distribution the user shut down.** The share is served
/// by a plan9 daemon *inside* the distribution, so listing it starts one that
/// is stopped — and an app that quietly resurrects a distribution every
/// 400 ms after `wsl --shutdown` is a worse neighbour than one that misses a
/// hook. So the running set is refreshed every [runningRefresh] by a query that
/// starts nothing, and a distribution that is not in it is skipped. Nothing is
/// lost by skipping: a distribution with no processes has no agent to fire a
/// hook. When it comes back it reappears in the set and draining resumes, and
/// the payloads that were written before it stopped are still in the directory.
///
/// Fails **open**: a running-set query that errors is read as "all of them",
/// because polling a distribution needlessly costs a millisecond and skipping
/// one wrongly costs every status it would have reported.
class AgentHookSpoolDrainer {
  AgentHookSpoolDrainer({
    required this.onEvent,
    this.spool = const AgentHookSpool(),
    this.interval = const Duration(milliseconds: 400),
    this.runningRefresh = const Duration(seconds: 15),
    this.maxPerTick = 64,
    this.runningDistributions = wslRunningDistributions,
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

  Timer? _timer;
  List<AgentHookSpoolSource> _sources = const [];
  Set<String>? _running;
  DateTime? _runningAt;
  bool _draining = false;

  /// The directories being polled, or none. Exposed for the settings surface
  /// and for tests; the app has no reason to read it.
  List<AgentHookSpoolSource> get sources => List.unmodifiable(_sources);

  /// Starts polling [sources], replacing whatever was being polled before.
  ///
  /// An empty list stops the timer rather than running it over nothing, which
  /// is the usual case: a machine with no WSL, or one where every store went to
  /// the HTTP transport.
  void watch(List<AgentHookSpoolSource> sources) {
    _sources = List.unmodifiable(sources);
    _timer?.cancel();
    _timer = null;
    if (_sources.isEmpty) return;
    _timer = Timer.periodic(interval, (_) => unawaited(drainOnce()));
  }

  /// One pass over every source. Public so a test can step the loop.
  ///
  /// Re-entrant calls are dropped rather than queued: a tick that is still
  /// waiting on a distribution has nothing to gain from a second one behind it,
  /// and the files it has not read yet will still be there.
  Future<void> drainOnce() async {
    if (_draining) return;
    _draining = true;
    try {
      final running = await _runningSet();
      for (final source in _sources) {
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

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _sources = const [];
  }
}
