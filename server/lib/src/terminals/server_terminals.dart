import 'dart:async';
import 'dart:io';

import 'package:agent_cli/descriptors.dart' show AgentRegistry;
import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_launch/karmashala_launch.dart';

import '../data/terminal_work.dart';
import 'package:karmashala_host_protocol/protocol.dart';

import '../domain/host_session.dart';
import '../domain/screen_session.dart';
import '../domain/session_registry.dart';
import '../pty/pty.dart';
import '../sessions/pane_facts.dart';
import '../sessions/pane_source.dart';
import '../ssh/ssh_domain.dart' show RemoteSessionRefused, RemoteSessions;

/// What every terminal this server starts on its own machine is told about the
/// screen it draws on. The pane is an xterm with 24-bit colour, and ConPTY
/// passes `38;2;r;g;b` through unchanged (measured 2026-09-29), so a program
/// that looks for `COLORTERM` — Codex does — draws its real palette rather
/// than a 256-colour approximation. A launch's own environment overrides both.
const Map<String, String> kTerminalEnvironment = {
  'TERM': 'xterm-256color',
  'COLORTERM': 'truecolor',
};

/// Colour opt-outs withheld from a terminal when they are merely **inherited**
/// from the server's own environment. The server's environment is whatever
/// process happened to start it: an app launched from an agent's shell passes
/// on that shell's `NO_COLOR=1` — Claude Code sets it for every command it
/// runs (observed 2026-09-29 on a host an agent's `flutter run` started:
/// `NO_COLOR=1` beside `CLAUDECODE=1`) — and every Claude Code and Codex pane
/// the long-lived host then opens honours it and renders without a single
/// colour. Removal comes before a launch's own environment is laid over, so a
/// `NO_COLOR` a person sets in the environment vault still reaches the pane.
const Set<String> kInheritedColourOptOuts = {'NO_COLOR'};

/// The markers an agent CLI sets for its own children (`CLAUDECODE`,
/// `CLAUDE_CODE_*`, …, each descriptor's `parentSessionEnvironment`),
/// withheld from **every** pane, not only agent launches: a host started from
/// an agent's shell carries them (observed 2026-09-29), and a `claude` typed
/// into a plain shell pane would otherwise believe it runs inside another
/// Claude session - a child session, which saves no transcript.
final Set<String> kInheritedAgentMarkers = {
  for (final descriptor in AgentRegistry.builtIn.descriptors)
    ...descriptor.launch.parentSessionEnvironment,
};

/// **Every local and WSL terminal, run by the server** (slice 5a). A client
/// names a profile or an agent launch; the launch is built here, with this
/// machine's OS, its shells and its environment vault, and started in the
/// server's own registry under the pane's session id
/// (`terminalSessionId`) — so it keeps running with every client closed,
/// and any client attaches to it by id. What each screen says about itself
/// is read off the server's copy of it and told as [TerminalChanged] — and,
/// as [PaneFacts], read by adoption, attribution and worktree cleanup (slice
/// 5c: no client reports its panes any more). **An SSH box's terminal**
/// (slice 5d) is opened on the box's Karmashala host through [remote]: the
/// box user's login shell, or the agent's own command, under the same pane id
/// — its record says `ssh:<hostId>/<id>`, which a client attaches to here.
class ServerTerminals implements TerminalWork, PaneSource {
  ServerTerminals({
    required this.registry,
    required List<ExecutionEnvironment> Function() environments,
    required void Function(List<DataChange> changes) tell,
    Map<String, String> Function()? overlay,
    Map<String, String>? hostEnvironment,
    List<String> Function()? installedShells,
    bool? windows,
    DateTime Function()? clock,
    this.settle = const Duration(milliseconds: 250),
    this.remote,
  }) : _environments = environments,
       _tell = tell,
       _overlay = overlay ?? (() => const {}),
       _hostEnvironment = hostEnvironment ?? Platform.environment,
       _installedShells = installedShells ?? _readEtcShells,
       _windows = windows ?? Platform.isWindows,
       _now = clock ?? _utcNow;

  final SessionRegistry registry;

  /// Sessions on SSH boxes (the ssh domain's); null opens none there.
  final RemoteSessions? remote;
  final List<ExecutionEnvironment> Function() _environments;
  final void Function(List<DataChange> changes) _tell;
  final Map<String, String> Function() _overlay;
  final Map<String, String> _hostEnvironment;
  final List<String> Function() _installedShells;
  final bool _windows;
  final DateTime Function() _now;

  /// How long a screen's moves are gathered before they are told: a TUI that
  /// animates its title must not become a change per frame for every client.
  final Duration settle;

  final _records = <String, TerminalRecord>{};

  /// Titles a person gave, over whatever the program sets.
  final _renamed = <String, String>{};
  final _dirty = <String>{};
  Timer? _flush;

  /// Where each terminal was started, before its shell says (OSC 7).
  final _launchDirectory = <String, String>{};

  /// Terminals started to run an agent's session — launched, never adopted.
  final _agentTerminals = <String>{};

  /// Told whenever a terminal starts, moves (title, folder, a command) or
  /// ends: the panes' facts are worth reading again.
  void Function()? onPanesChanged;

  @override
  List<PaneFacts> get all => [
    for (final record in _records.values) _factsOf(record),
  ];

  @override
  List<String>? tailOf(String paneId, int lines) {
    for (final record in _records.values) {
      if (record.paneId != paneId) continue;
      return _sessionOf(record.sessionId)?.tailText(lines);
    }
    return null;
  }

  PaneFacts _factsOf(TerminalRecord record) {
    final session = _sessionOf(record.sessionId);
    final facts = session?.facts;
    final count = facts?.commandCount ?? 0;
    return PaneFacts(
      paneId: record.paneId,
      live: session != null && !session.lifecycle.hasEnded,
      workingDirectory:
          facts?.workingDirectory ?? _launchDirectory[record.sessionId],
      hostsLaunchedSession: _agentTerminals.contains(record.sessionId),
      lastCommandId: count == 0 ? null : '${record.sessionId}#$count',
      lastCommandLine: facts?.lastCommand,
      lastCommandRunning: facts == null || !facts.lastCommandEnded,
    );
  }

  static DateTime _utcNow() => DateTime.now().toUtc();

  /// The session a record names: one of the registry's, or — `ssh:<host>/<id>`
  /// — the server's copy of one on a box.
  ScreenSession? _sessionOf(String sessionId) {
    final box = parseBoxSessionRef(sessionId);
    return box == null
        ? registry.find(sessionId)
        : remote?.byId(box.sessionId);
  }

  List<TerminalRecord> get records => List.unmodifiable(_records.values);

  @override
  List<DataChange> greeting() => [
    for (final record in _records.values) TerminalChanged(record),
  ];

  @override
  Future<Object?> handle(TerminalWorkRequest<Object?> request) async =>
      switch (request) {
        TerminalsProfiles() => profiles(),
        final TerminalOpen open => await openAnywhere(open),
        TerminalsList() => records,
        TerminalClose(:final sessionId) => await close(sessionId),
        TerminalRename(:final sessionId, :final title) => rename(
          sessionId,
          title,
        ),
      };

  /// The shells this machine opens, spelled for its own OS.
  List<TerminalProfile> profiles() {
    final login = _loginShell();
    return terminalProfilesFor(
      [
        // A box's shell is its own login shell (slice 5d); a WSL
        // distribution only exists to a Windows server.
        for (final environment in _environments())
          if (environment.kind == EnvironmentKind.wsl && _windows) environment,
      ],
      hostIsWindows: _windows,
      loginShell: login,
      shells: _windows ? const [] : _installedShells(),
    );
  }

  /// [request]'s terminal wherever its environment is: on this machine
  /// ([open]) or on an SSH box through the box's host. Throws [DataRefused].
  Future<TerminalOpened> openAnywhere(TerminalOpen request) async {
    final box = _boxOf(request);
    return box == null ? open(request) : _openOnBox(request, box);
  }

  /// The SSH environment [request] opens in, or null for this machine's.
  ExecutionEnvironment? _boxOf(TerminalOpen request) {
    final hostId = request.agentLaunch?.sshHostId;
    final environments = _environments();
    if (hostId != null) {
      return environments
              .where(
                (e) => e.kind == EnvironmentKind.ssh && e.sshHostId == hostId,
              )
              .firstOrNull ??
          (throw DataRefused.notFound('no SSH machine is saved as $hostId'));
    }
    final id = request.environmentId;
    if (id == null) return null;
    final environment = environments.where((e) => e.id == id).firstOrNull;
    return environment?.kind == EnvironmentKind.ssh ? environment : null;
  }

  Future<TerminalOpened> _openOnBox(
    TerminalOpen request,
    ExecutionEnvironment box,
  ) async {
    final remote = this.remote;
    if (remote == null || !remote.reaches(box)) {
      throw DataRefused.notFound(
        '${box.name} is an SSH machine this server does not reach.',
      );
    }
    final agent = request.agentLaunch;
    final ownId = terminalSessionId(
      paneId: request.paneId,
      agentSessionId: agent?.sessionId,
    );
    final ref = boxSessionRef(box.sshHostId!, ownId);
    final running = remote.byId(ownId);
    if (running == null || running.lifecycle.hasEnded) {
      if (request.columns <= 0 || request.rows <= 0) {
        throw const DataRefused.invalid('terminals.open: an empty grid');
      }
    }
    final title = agent?.title ?? agent?.agentId ?? box.name;
    final ({ScreenSession session, bool adopted}) opened;
    try {
      final started = await remote.open(
        box,
        sessionId: ownId,
        argv: agent == null
            ? null
            : [agent.executable, ...agent.commandArguments],
        workingDirectory: agent?.workingDirectory ?? request.workingDirectory,
        variables: agent == null
            ? const {}
            : {
                kSessionIdEnvironmentVariable: agent.sessionId ?? '',
                ...agent.environment,
              },
        removedVariables: agent?.removedEnvironment ?? const {},
        columns: request.columns,
        rows: request.rows,
      );
      opened = (session: started.session, adopted: started.adopted);
    } on RemoteSessionRefused catch (error) {
      throw DataRefused(DataRefusalCode.failed, error.message);
    }
    final directory = agent?.workingDirectory ?? request.workingDirectory;
    if (directory != null) _launchDirectory[ref] = directory;
    if (agent != null) _agentTerminals.add(ref);
    final record =
        (opened.adopted ? _records[ref] : null) ??
        _track(
          opened.session,
          sessionId: ref,
          paneId: request.paneId,
          profileId: agent?.profileId ?? request.profileId ?? '',
          environmentId: box.id,
          title: title,
          shellIntegration: false,
          tell: true,
        );
    return TerminalOpened(
      sessionId: ref,
      paneId: request.paneId,
      title: record.title,
      profileId: record.profileId,
      shellIntegration: false,
      adopted: opened.adopted,
    );
  }

  /// Starts [request]'s terminal on this machine, or answers the one already
  /// running under its pane's id. Throws [DataRefused].
  TerminalOpened open(TerminalOpen request) {
    final agent = request.agentLaunch;
    final sessionId = terminalSessionId(
      paneId: request.paneId,
      agentSessionId: agent?.sessionId,
    );
    final running = registry.find(sessionId);
    if (running != null && !running.lifecycle.hasEnded) {
      final record =
          _records[sessionId] ??
          _track(
            running,
            paneId: request.paneId,
            profileId: agent?.profileId ?? request.profileId ?? '',
            environmentId: request.environmentId,
            title: agent?.title ?? agent?.agentId ?? 'Terminal',
            shellIntegration: false,
            tell: true,
          );
      return TerminalOpened(
        sessionId: sessionId,
        paneId: request.paneId,
        title: record.title,
        profileId: record.profileId,
        shellIntegration: record.shellIntegration,
        adopted: true,
      );
    }
    if (request.columns <= 0 || request.rows <= 0) {
      throw const DataRefused.invalid('terminals.open: an empty grid');
    }
    final environment = _environmentFor(request);
    final profile = _profileFor(request, environment);
    final overlay = _overlay();
    final built = terminalLaunchFor(
      profile: profile,
      agentLaunch: agent,
      workingDirectory: agent?.workingDirectory ?? request.workingDirectory,
      hostIsWindows: _windows,
      posixShell: _loginShell(),
      shellIntegration: request.shellIntegration,
      overlay: overlay,
    );
    final launch = built.launch;
    final HostSession session;
    try {
      session = registry.open(
        sessionId,
        PtySpawnRequest(
          argv: launch.hostArgv,
          // The launch's own, never the client's: a WSL launch carries its
          // Linux folder as `--cd`, which CreateProcess would refuse.
          workingDirectory: launch.workingDirectory,
          environment: {...kTerminalEnvironment, ...launch.environment},
          removedEnvironment: {
            ...kInheritedColourOptOuts,
            ...kInheritedAgentMarkers,
            ...launch.removedEnvironment,
          },
          unrecorded: {
            for (final name in overlay.keys)
              if (launch.environment.containsKey(name)) name,
          },
          columns: request.columns,
          rows: request.rows,
        ),
      );
    } on SessionAlreadyExists {
      throw DataRefused.invalid('$sessionId is already running');
    } on Object catch (error) {
      throw DataRefused(
        DataRefusalCode.failed,
        '${built.title} could not be started: $error',
      );
    }
    _renamed.remove(sessionId);
    final directory = agent?.workingDirectory ?? request.workingDirectory;
    if (directory != null) {
      _launchDirectory[sessionId] = directory;
    } else {
      _launchDirectory.remove(sessionId);
    }
    if (agent != null) {
      _agentTerminals.add(sessionId);
    } else {
      _agentTerminals.remove(sessionId);
    }
    _track(
      session,
      paneId: request.paneId,
      profileId: built.profileId,
      environmentId: environment?.id ?? request.environmentId,
      title: built.title,
      shellIntegration: built.shellIntegration,
      tell: true,
    );
    return TerminalOpened(
      sessionId: sessionId,
      paneId: request.paneId,
      title: built.title,
      profileId: built.profileId,
      shellIntegration: built.shellIntegration,
    );
  }

  /// Ends [sessionId] for good and forgets it.
  Future<DataAck> close(String sessionId) async {
    final box = parseBoxSessionRef(sessionId);
    try {
      if (box != null) {
        final remote = this.remote;
        if (remote == null) throw UnknownSession(sessionId);
        try {
          await remote.close(box.sessionId);
        } on RemoteSessionRefused {
          throw UnknownSession(sessionId);
        }
      } else {
        await registry.close(sessionId);
      }
    } on UnknownSession {
      if (_records.remove(sessionId) == null) {
        throw DataRefused.notFound('no terminal $sessionId on this server');
      }
    }
    _records.remove(sessionId);
    _renamed.remove(sessionId);
    _dirty.remove(sessionId);
    _forgetPane(sessionId);
    _tell([TerminalRemoved(sessionId)]);
    onPanesChanged?.call();
    return const DataAck();
  }

  DataAck rename(String sessionId, String title) {
    final record = _records[sessionId];
    if (record == null) {
      throw DataRefused.notFound('no terminal $sessionId on this server');
    }
    final trimmed = title.trim();
    if (trimmed.isEmpty) {
      _renamed.remove(sessionId);
    } else {
      _renamed[sessionId] = trimmed;
    }
    _refresh(sessionId);
    _flushNow();
    return const DataAck();
  }

  Future<void> dispose() async {
    _flush?.cancel();
    _flush = null;
  }

  TerminalRecord _track(
    ScreenSession session, {
    String? sessionId,
    required String paneId,
    required String profileId,
    required String? environmentId,
    required String title,
    required bool shellIntegration,
    required bool tell,
  }) {
    final named = sessionId ?? session.id;
    final record = TerminalRecord(
      sessionId: named,
      paneId: paneId,
      profileId: profileId,
      environmentId: environmentId,
      shellIntegration: shellIntegration,
      title: title,
      startedAt: session.startedAt.toUtc(),
    );
    _records[named] = record;
    final facts = session.facts;
    if (facts != null) {
      facts.onChanged = () {
        if (!_records.containsKey(named)) return;
        _dirty.add(named);
        _flush ??= Timer(settle, _flushNow);
      };
    }
    unawaited(
      session.ended.then((end) {
        if (_sessionOf(named) != session) return;
        final current = _records[named];
        if (current == null) return;
        _records[named] = current.copyWith(
          endedAt: (end.endedAt ?? _now()).toUtc(),
          exitCode: end.exitCode,
          endReason: switch (end) {
            SessionEndedWithoutCode(:final reason) => reason,
            _ => null,
          },
        );
        _dirty.add(named);
        _flushNow();
        _prune();
      }),
    );
    if (tell) _tell([TerminalChanged(record)]);
    onPanesChanged?.call();
    return record;
  }

  void _forgetPane(String sessionId) {
    _launchDirectory.remove(sessionId);
    _agentTerminals.remove(sessionId);
  }

  /// [sessionId]'s record as its screen and a rename now say.
  void _refresh(String sessionId) {
    final current = _records[sessionId];
    final session = _sessionOf(sessionId);
    if (current == null) return;
    final facts = session?.facts;
    _records[sessionId] = TerminalRecord(
      sessionId: current.sessionId,
      paneId: current.paneId,
      profileId: current.profileId,
      environmentId: current.environmentId,
      shellIntegration: current.shellIntegration,
      title: _renamed[sessionId] ?? _nonEmpty(facts?.title) ?? current.title,
      workingDirectory: facts?.workingDirectory ?? current.workingDirectory,
      lastCommand: facts?.lastCommand ?? current.lastCommand,
      lastCommandExitCode: facts == null
          ? current.lastCommandExitCode
          : facts.lastCommandExitCode,
      startedAt: current.startedAt,
      endedAt: current.endedAt,
      exitCode: current.exitCode,
      endReason: current.endReason,
    );
  }

  void _flushNow() {
    _flush?.cancel();
    _flush = null;
    if (_dirty.isEmpty) return;
    final changes = <DataChange>[];
    for (final sessionId in _dirty) {
      _refresh(sessionId);
      final record = _records[sessionId];
      if (record != null) changes.add(TerminalChanged(record));
    }
    _dirty.clear();
    if (changes.isNotEmpty) _tell(changes);
    onPanesChanged?.call();
  }

  /// Drops the records of sessions the registry let go of (its own bound on
  /// ended sessions), telling each removal.
  void _prune() {
    final gone = [
      for (final sessionId in _records.keys)
        if (_sessionOf(sessionId) == null) sessionId,
    ];
    if (gone.isEmpty) return;
    for (final sessionId in gone) {
      _records.remove(sessionId);
      _renamed.remove(sessionId);
      _forgetPane(sessionId);
    }
    _tell([for (final sessionId in gone) TerminalRemoved(sessionId)]);
  }

  ExecutionEnvironment? _environmentFor(TerminalOpen request) {
    final id = request.environmentId;
    if (id == null) return null;
    final environment = _environments().where((e) => e.id == id).firstOrNull;
    if (environment == null) {
      throw DataRefused.notFound('Unknown environment: $id');
    }
    switch (environment.kind) {
      case EnvironmentKind.ssh:
        // Opened on the box (`openAnywhere`); never a PTY here.
        throw DataRefused.notFound(
          '${environment.name} is an SSH machine: its terminals open on the '
          'box, through the server\'s link to it.',
        );
      case EnvironmentKind.wsl when !_windows:
        throw DataRefused.notFound(
          '${environment.name} is a WSL distribution, and this server is not '
          'on Windows, so it cannot reach it.',
        );
      case EnvironmentKind.localPosix when _windows:
      case EnvironmentKind.windowsNative when !_windows:
        throw DataRefused.notFound(
          '${environment.name} is not this server\'s machine.',
        );
      default:
        return environment;
    }
  }

  TerminalProfile _profileFor(
    TerminalOpen request,
    ExecutionEnvironment? environment,
  ) {
    final offered = profiles();
    final distro = environment?.kind == EnvironmentKind.wsl
        ? environment!.wslDistribution
        : null;
    final asked = request.profileId;
    if (request.agentLaunch != null) {
      // An agent pane runs its own command; the profile only names a shell
      // nobody starts. The server's default stands in.
      return offered.isNotEmpty ? offered.first : TerminalProfile.powerShell;
    }
    if (asked == null) {
      if (distro != null && distro.isNotEmpty) {
        final wsl = terminalProfileFromId(TerminalProfile.wslId(distro));
        if (wsl != null) return wsl;
      }
      if (offered.isEmpty) {
        throw const DataRefused.invalid('this server offers no shell');
      }
      return offered.first;
    }
    for (final profile in offered) {
      if (profile.id == asked) return profile;
    }
    throw DataRefused.invalid(
      'this server does not offer the shell "$asked" — it offers '
      '${offered.map((p) => p.label).join(', ')}',
    );
  }

  String? _loginShell() {
    final shell = _hostEnvironment['SHELL']?.trim();
    if (shell == null || !shell.startsWith('/')) return null;
    return shell;
  }

  static String? _nonEmpty(String? value) =>
      value == null || value.trim().isEmpty ? null : value;

  /// The shells in `/etc/shells` that exist: the system's own answer to what
  /// can be a login shell.
  static List<String> _readEtcShells() {
    try {
      final file = File('/etc/shells');
      if (!file.existsSync()) return const [];
      final shells = <String>[];
      for (final line in file.readAsLinesSync()) {
        final path = line.trim();
        if (path.isEmpty || path.startsWith('#') || !path.startsWith('/')) {
          continue;
        }
        if (shells.contains(path) || !File(path).existsSync()) continue;
        shells.add(path);
      }
      return shells;
    } on FileSystemException {
      return const [];
    }
  }
}
