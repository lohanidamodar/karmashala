import 'dart:async';
import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_agent_reporting/hooks.dart';

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
  ///
  /// For a WSL store this path is only ever *listed by name* ([AgentHookSpool.
  /// hasPayloads]); the payloads themselves are read from inside the
  /// distribution ([linuxDirectory]), so a Windows host never opens one and
  /// on-access antivirus never scans it (docs/windows-antivirus.md).
  final Directory directory;

  /// The distribution this store lives in, when it lives in one. Read to decide
  /// whether the store is running at all, and to read its payloads over
  /// `wsl.exe` rather than over the scanned `\\wsl.localhost` share.
  final String? wslDistribution;

  /// The store's path **inside** its distribution, or `null` when it is not a
  /// WSL store. Derived from [directory]'s UNC spelling.
  String? get linuxDirectory => wslDistribution == null
      ? null
      : AgentHookSpool.wslLinuxPathOf(directory.path);
}

/// Which WSL distributions are running, without starting any that are not:
/// `wsl.exe -l --running -q` is answered on the Windows side, off the isolate.
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

/// Reads and clears a WSL spool **from inside its distribution**, over
/// `wsl.exe`, so the payloads cross on a pipe rather than through the
/// antivirus-scanned `\\wsl.localhost` share. The default runs the real
/// `wsl.exe`; a test injects its own.
Future<List<AgentHookSpoolEvent>> wslSpoolDrain({
  required String distribution,
  required String linuxDirectory,
  int limit = 64,
  AgentHookSpool spool = const AgentHookSpool(),
}) async {
  try {
    final result = await sharedProcessSpawner.run(
      CommandRequest(
        executable: 'wsl.exe',
        arguments: AgentHookSpool.wslDrainArguments(
          distribution: distribution,
          linuxDirectory: linuxDirectory,
          limit: limit,
        ),
      ),
    );
    if (result.exitCode != 0) return const [];
    return spool.parseDrained(result.stdout);
  } on Object {
    return const [];
  }
}

/// How a WSL spool's payloads are read once its directory is known to hold
/// some. Injected so a test drives no `wsl.exe`.
typedef WslSpoolDrain =
    Future<List<AgentHookSpoolEvent>> Function({
      required String distribution,
      required String linuxDirectory,
      int limit,
    });

/// How the drainer arms its polling loop and takes it down: real-`Timer`
/// defaults, so the app runs on a clock and a test steps one.
typedef PeriodicSchedule =
    Object Function(Duration interval, void Function() tick);
typedef CancelPeriodic = void Function(Object handle);

/// Polls the spool directories WSL agents write their payloads into: a poll
/// because `Directory.watch` never fires there, and never wakes a stopped one.
class AgentHookSpoolDrainer {
  AgentHookSpoolDrainer({
    required this.onEvent,
    this.spool = const AgentHookSpool(),
    this.interval = const Duration(milliseconds: 400),
    this.runningRefresh = const Duration(seconds: 15),
    this.maxPerTick = 64,
    this.runningDistributions = wslRunningDistributions,
    this.wslDrain = wslSpoolDrain,
    this.schedule = _defaultSchedule,
    this.cancelSchedule = _defaultCancel,
  });

  /// What one drained payload does. Wired to `applyAgentHookCallback` in the
  /// provider; injected here so the loop can be driven with no container.
  final void Function(AgentHookSpoolEvent event) onEvent;

  final AgentHookSpool spool;
  final Duration interval;
  final Duration runningRefresh;

  /// How many payloads one tick takes from one directory, so a backlog from an
  /// unclean exit is spread over ticks rather than held on the isolate.
  final int maxPerTick;

  /// See the class doc. Injected so a test never spawns `wsl.exe`.
  final Future<Set<String>> Function() runningDistributions;

  /// How a WSL store's payloads are read — over `wsl.exe`, from inside the
  /// distribution, never over `\\wsl.localhost`. Injected so a test spawns no
  /// `wsl.exe`; a store on this machine's own filesystem does not use it.
  final WslSpoolDrain wslDrain;

  /// How the loop is armed and taken down. Injected because a real `Timer`
  /// makes a test wait, and a waiting test measures the scheduler.
  final PeriodicSchedule schedule;
  final CancelPeriodic cancelSchedule;

  Object? _handle;
  List<AgentHookSpoolSource> _sources = const [];
  Set<String>? _running;
  DateTime? _runningAt;
  bool _draining = false;
  bool _disposed = false;
  Future<void>? _inFlight;

  /// The drain the last tick started. For the one caller that must know when a
  /// tick it *fired* has finished: a test stepping the loop.
  Future<void> get settled => _inFlight ?? Future<void>.value();

  /// The directories being polled, or none. Exposed for the settings surface
  /// and for tests; the app has no reason to read it.
  List<AgentHookSpoolSource> get sources => List.unmodifiable(_sources);

  /// Starts polling [sources], replacing whatever was polled before. An empty
  /// list stops the timer rather than running it over nothing.
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

  /// One pass over every source; public so a test can step the loop. Re-entrant
  /// calls are dropped, since the files will still be there next tick.
  Future<void> drainOnce() async {
    if (_draining || _disposed) return;
    _draining = true;
    try {
      final running = await _runningSet();
      // **Checked between sources, not once at the top**: a drain already
      // awaiting a distribution would delete payloads nobody owns any more.
      for (final source in _sources) {
        if (_disposed) return;
        final distribution = source.wslDistribution;
        if (distribution != null &&
            running != null &&
            !running.contains(distribution)) {
          continue;
        }
        final events = await _drain(source);
        if (_disposed) return;
        for (final event in events) {
          onEvent(event);
        }
      }
    } finally {
      _draining = false;
    }
  }

  /// One source's payloads. A WSL store is **listed by name** first (nothing
  /// opened over the share) and, only if it holds something, read from inside
  /// the distribution over `wsl.exe`. A store on this machine's own filesystem
  /// is read directly. Never throws.
  Future<List<AgentHookSpoolEvent>> _drain(AgentHookSpoolSource source) async {
    final distribution = source.wslDistribution;
    final linux = source.linuxDirectory;
    if (distribution == null || linux == null) {
      return spool.drain(source.directory, limit: maxPerTick);
    }
    // The name-only look is what keeps the common case — an idle share with no
    // payload — from ever opening a file the antivirus would scan, and from
    // spending a `wsl.exe` on nothing.
    if (!await spool.hasPayloads(source.directory)) return const [];
    return wslDrain(
      distribution: distribution,
      linuxDirectory: linux,
      limit: maxPerTick,
    );
  }

  /// The running distributions, refreshed at most every [runningRefresh], or
  /// `null` when the answer is not to be trusted and all should be polled.
  Future<Set<String>?> _runningSet() async {
    final needsDistribution = _sources.any((s) => s.wslDistribution != null);
    if (!needsDistribution) return null;
    final at = _runningAt;
    if (at != null && DateTime.now().difference(at) < runningRefresh) {
      return _running;
    }
    final running = await runningDistributions();
    _runningAt = DateTime.now();
    // An empty answer fails open: polling a stopped distribution costs a
    // wake-up, and not polling a running one costs every status in it.
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
