import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart' show CliStore;
import 'package:karmashala_agent_reporting/hooks.dart';

import 'package:karmashala_host_protocol/protocol.dart' show AgentHookEvent;

/// Set to `off` and a server drains no WSL hook spool — a test's server, whose
/// temporary HOME is not where the owner's distributions write theirs.
const String kHookSpoolsVariable = 'KARMASHALA_HOOK_SPOOLS';

/// One WSL agent store's spool: where its hook script writes a payload,
/// because a WSL agent cannot reach any address this server binds.
class HookSpoolSource {
  const HookSpoolSource({
    required this.environmentId,
    required this.distribution,
    required this.directory,
  });

  final String environmentId;
  final String distribution;

  /// The spool in this server's spelling, `\\wsl.localhost\<distro>\…`: only
  /// ever **listed by name** here, never opened (docs/windows-antivirus.md).
  final String directory;

  /// The same directory inside the distribution, where it is read from.
  String? get linuxDirectory => AgentHookSpool.wslLinuxPathOf(directory);

  @override
  bool operator ==(Object other) =>
      other is HookSpoolSource &&
      other.environmentId == environmentId &&
      other.distribution == distribution &&
      other.directory == directory;

  @override
  int get hashCode => Object.hash(environmentId, distribution, directory);
}

/// Every spool the agents in [environments]' WSL distributions write into,
/// from their located [stores]: one per agent that takes hooks and has a
/// store there — the directory `AgentHookInstaller.spoolDirectoryFor` names,
/// the one the app's installer writes the scripts for.
List<HookSpoolSource> wslHookSpoolSources({
  required List<CliStore> stores,
  required List<ExecutionEnvironment> environments,
  AgentRegistry registry = AgentRegistry.builtIn,
  AgentHookInstaller installer = const AgentHookInstaller(),
}) {
  final byId = {for (final e in environments) e.id: e};
  return [
    for (final store in stores)
      if (byId[store.environmentId] case final environment?
          when environment.kind == EnvironmentKind.wsl &&
              (environment.wslDistribution ?? '').isNotEmpty)
        for (final descriptor in registry.descriptors)
          if (descriptor.hooks != null)
            if (store.homesByAgentId[descriptor.id] case final home?)
              if (installer.spoolDirectoryFor(descriptor, home)
                  case final spool?)
                HookSpoolSource(
                  environmentId: environment.id,
                  distribution: environment.wslDistribution!,
                  directory: spool.path,
                ),
  ];
}

/// Drains the WSL agents' hook spools into the server's own hook intake
/// (slice 5a; the app's `AgentHookSpoolDrainer`, moved). A poll, because
/// `Directory.watch` never fires over `\\wsl.localhost` — and a stopped
/// distribution is never polled, so none is woken. Each payload is read from
/// **inside** its distribution over `wsl.exe`, crossing on a pipe; a hook is
/// never held (its tool has already run).
class HookSpools {
  HookSpools({
    required this.sources,
    required this.onHook,
    Future<CommandResult> Function(CommandRequest request)? run,
    Future<bool> Function(String directory)? hasPayloads,
    this.interval = const Duration(milliseconds: 400),
    this.sourcesRefresh = const Duration(minutes: 1),
    this.runningRefresh = const Duration(seconds: 15),
    this.maxPerTick = 64,
    DateTime Function()? clock,
  }) : _run = run ?? sharedProcessSpawner.run,
       _hasPayloads = hasPayloads ?? _listedPayloads,
       _now = clock ?? DateTime.now;

  /// Where the spools are now: re-read every [sourcesRefresh], so a
  /// distribution or agent found later is drained without a restart.
  final Future<List<HookSpoolSource>> Function() sources;

  /// The server's hook intake — the closure its loopback endpoint calls.
  final FutureOr<void> Function(AgentHookEvent hook) onHook;

  final Future<CommandResult> Function(CommandRequest request) _run;
  final Future<bool> Function(String directory) _hasPayloads;
  final DateTime Function() _now;
  final Duration interval;
  final Duration sourcesRefresh;
  final Duration runningRefresh;

  /// How many payloads one tick takes from one spool, so a backlog left by an
  /// unclean exit is spread over ticks.
  final int maxPerTick;

  static const _spool = AgentHookSpool();

  Timer? _timer;
  List<HookSpoolSource> _sources = const [];
  DateTime? _sourcesAt;
  Set<String>? _running;
  DateTime? _runningAt;
  var _draining = false;
  var _closed = false;

  /// The spools the last refresh found.
  List<HookSpoolSource> get current => List.unmodifiable(_sources);

  void start() {
    if (_closed) return;
    _timer ??= Timer.periodic(interval, (_) => unawaited(drainOnce()));
  }

  void close() {
    _closed = true;
    _timer?.cancel();
    _timer = null;
  }

  /// One pass over every spool; public so a test steps it. A pass still
  /// running when the next tick fires is not doubled.
  Future<void> drainOnce() async {
    if (_draining || _closed) return;
    _draining = true;
    try {
      await _refreshSources();
      if (_sources.isEmpty) return;
      final running = await _runningSet();
      for (final source in _sources) {
        // Checked between spools: a pass awaiting a distribution must not
        // take payloads after the server was told to stop.
        if (_closed) return;
        if (running != null && !running.contains(source.distribution)) {
          continue;
        }
        for (final event in await _drain(source)) {
          if (_closed) return;
          final hook = _asHook(event);
          if (hook != null) await onHook(hook);
        }
      }
    } finally {
      _draining = false;
    }
  }

  Future<void> _refreshSources() async {
    final at = _sourcesAt;
    if (at != null && _now().difference(at) < sourcesRefresh) return;
    _sourcesAt = _now();
    try {
      _sources = List.unmodifiable(await sources());
    } on Object {
      // Kept as they were: a store that did not answer this minute still
      // holds the spools it held.
    }
  }

  /// A spool is listed by name first (nothing opened over the share) and,
  /// only when it holds something, read from inside its distribution.
  Future<List<AgentHookSpoolEvent>> _drain(HookSpoolSource source) async {
    final linux = source.linuxDirectory;
    if (linux == null) return const [];
    if (!await _hasPayloads(source.directory)) return const [];
    try {
      final result = await _run(
        CommandRequest(
          executable: 'wsl.exe',
          arguments: AgentHookSpool.wslDrainArguments(
            distribution: source.distribution,
            linuxDirectory: linux,
            limit: maxPerTick,
          ),
        ),
      );
      if (result.exitCode != 0) return const [];
      return _spool.parseDrained(result.stdout);
    } on Object {
      return const [];
    }
  }

  /// The running distributions, asked of Windows without starting any, at
  /// most every [runningRefresh]; null polls them all (an empty or failed
  /// answer fails open: a missed status costs more than one wake-up).
  Future<Set<String>?> _runningSet() async {
    final at = _runningAt;
    if (at != null && _now().difference(at) < runningRefresh) return _running;
    _runningAt = _now();
    try {
      final result = await _run(
        const CommandRequest(
          executable: 'wsl.exe',
          arguments: ['-l', '--running', '-q'],
        ),
      );
      final names = result.exitCode == 0
          ? parseWslDistributions(result.stdout).toSet()
          : const <String>{};
      _running = names.isEmpty ? null : names;
    } on Object {
      _running = null;
    }
    return _running;
  }

  /// A payload as the loopback endpoint would have taken it; one that is not
  /// a JSON object is dropped, as the endpoint drops it.
  static AgentHookEvent? _asHook(AgentHookSpoolEvent event) {
    final Object? decoded;
    try {
      decoded = jsonDecode(event.body);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, Object?>) return null;
    return AgentHookEvent(
      agent: event.agentId,
      event: event.event,
      sessionHeader: event.paneSessionId,
      receivedAt: event.firedAt.toUtc(),
      body: decoded,
    );
  }

  static Future<bool> _listedPayloads(String directory) =>
      _spool.hasPayloads(Directory(directory));
}
