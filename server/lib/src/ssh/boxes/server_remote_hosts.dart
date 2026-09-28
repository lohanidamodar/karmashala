import 'dart:async';

import 'package:agent_cli/process.dart';
import 'package:karmashala_host_protocol/protocol.dart';
import 'package:karmashala_ssh/connection.dart';
import 'package:karmashala_ssh_host/host.dart';

import '../../domain/write_token.dart';
import 'box_screen.dart';
import 'remote_sessions.dart';

/// A box the server cannot use right now, in a person's words.
class BoxUnavailable implements Exception {
  const BoxUnavailable(this.message, {this.deployment});

  final String message;

  /// The deploy that did not end ready, when that is why.
  final HostDeployment? deployment;

  @override
  String toString() => message;
}

/// **SSH boxes, reached by the server** (slice 5d). The server deploys the
/// Karmashala host on each box (`HostDeployer`, over its own pool — keys
/// read on the server's machine only), keeps **one link per box**
/// (`karmashala_host attach` over an exec channel) and:
///
/// - starts sessions there — a terminal, an agent, a worktree's setup, a
///   Flutter run — and keeps a copy of each one's screen ([BoxScreen]), so it
///   reads a box's sessions as it reads its own;
/// - **relays** a client's attachment: a client attaches to
///   `ssh:<hostId>/<sessionId>` (or the session's own id) at its own server,
///   and the relay (`ServerBoxRelay`) sends it the box's frames by ref;
/// - follows the box's lifecycle — an exit is the box host's fact, and the
///   session outlives the server restarting, because the box keeps it.
///
/// No tmux fallback (owner, 2026-09-27): a box that cannot run the host is
/// refused in words.
class ServerRemoteHosts implements RemoteSessions {
  ServerRemoteHosts({
    required SshHost? Function(String hostId) hostOf,
    required SshConnection Function(String hostId) connectionFor,
    required this.bundles,
    HostDeployTarget Function(SshHost host)? targetFor,
    this.onLifecycle,
    this.onHook,
    void Function(String message)? log,
    this.clientId = 'karmashala-server',
    this.refusal,
    this.relinkDelays = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 10),
      Duration(seconds: 30),
    ],
  }) : _hostOf = hostOf,
       _connectionFor = connectionFor,
       _targetFor = targetFor,
       _log = log ?? ((_) {});

  final SshHost? Function(String hostId) _hostOf;
  final SshConnection Function(String hostId) _connectionFor;
  final HostDeployTarget Function(SshHost host)? _targetFor;
  final HostBinarySource bundles;
  final String clientId;

  /// Why this server uses no box's host at all, or null when it may — a
  /// probe's: a box's host is per user there, and the owner's sessions are
  /// in it (PROJECT.md §23).
  final String? refusal;
  final List<Duration> relinkDelays;
  final void Function(String message) _log;

  /// Each lifecycle event a box host tells: its sessions' starts and exits.
  void Function(String hostId, LifecycleEvent event)? onLifecycle;

  /// Each agent hook a box host took.
  void Function(String hostId, AgentHookEvent hook)? onHook;

  final _access = <String, SshHostSessionAccess>{};
  final _links = <String, Future<BoxLink>>{};
  final _screens = <String, BoxScreen>{};
  final _tokens = <String, WriteToken>{};
  final _relinking = <String>{};

  /// A session the server started on a box, by its own id: that id is the
  /// same one a client computes for the pane (`terminalSessionId`,
  /// `hostedRunSessionId`), so a restored pane finds its box session without
  /// knowing it is on a box.
  final _aliases = <String, String>{};
  var _closed = false;

  /// The server's copies of the box sessions it knows, running or ended.
  Iterable<BoxScreen> get screens => _screens.values;

  /// The copy of [ref] (`ssh:<hostId>/<id>`), or null.
  BoxScreen? screenOf(String ref) => _screens[ref];

  /// The copy of the box session [sessionId] started under its own id.
  BoxScreen? screenById(String sessionId) {
    final hostId = _aliases[sessionId];
    return hostId == null ? null : _screens[boxSessionRef(hostId, sessionId)];
  }

  SshHost _host(String hostId) =>
      _hostOf(hostId) ??
      (throw BoxUnavailable('No SSH host is saved as $hostId.'));

  /// The deploy-and-greet access for [hostId]: one per box, its reading
  /// shared by every caller until the connection drops.
  SshHostSessionAccess accessOf(String hostId) {
    final host = _host(hostId);
    return _access[hostId] ??= SshHostSessionAccess(
      host: host,
      connection: _connectionFor(hostId),
      binaries: bundles,
    )..deployTarget = _targetFor?.call(host);
  }

  /// The box's host reading: deployed (or already there) and answering.
  Future<HostDeployment> deployment(String hostId) =>
      accessOf(hostId).deployment();

  /// Drops the shared reading, so the next use deploys and reads again.
  void forgetReading(String hostId) => _access[hostId]?.forgetReading();

  /// This box's login shell, for a shell pane's argv.
  Future<String?> loginShell(String hostId) => accessOf(hostId).loginShell();

  /// The one link to [hostId]'s host, deployed first if need be. Throws
  /// [BoxUnavailable] in words when the box cannot run it.
  Future<BoxLink> link(String hostId) {
    if (refusal case final why?) return Future.error(BoxUnavailable(why));
    if (_closed) {
      return Future.error(const BoxUnavailable('The server is stopping.'));
    }
    final existing = _links[hostId];
    if (existing != null) return existing;
    final opening = _openLink(hostId);
    _links[hostId] = opening;
    opening.then(
      (link) => link.closed.then((why) => _linkLost(hostId, link, why)),
      onError: (Object _) {
        if (_links[hostId] == opening) _links.remove(hostId);
      },
    );
    return opening;
  }

  Future<BoxLink> _openLink(String hostId) async {
    final host = _host(hostId);
    final access = accessOf(hostId);
    final HostDeployment reading;
    try {
      reading = await access.deployment();
    } on BoxUnavailable {
      rethrow;
    } on Object catch (error) {
      throw BoxUnavailable(
        'Could not reach ${host.name}: ${describeSshFailure(error)}',
      );
    }
    final remotePath = reading.remotePath;
    if (!reading.isReady || remotePath == null) {
      // Not kept: a Retry opens again, and what stopped this one — a bundle
      // not on the server yet, a box that could not unpack — may be fixed.
      access.forgetReading();
      throw BoxUnavailable(
        HostDeployFailure(hostName: host.name, deployment: reading).toString(),
        deployment: reading,
      );
    }
    final BoxLink link;
    try {
      link = await BoxLink.connect(
        await access.exec('$remotePath attach'),
        hostId: hostId,
        clientId: clientId,
      );
    } on BoxLinkException catch (error) {
      access.forgetReading();
      throw BoxUnavailable('The Karmashala host on ${host.name}: $error');
    }
    link.events.listen((message) {
      switch (message) {
        case LifecycleMessage(:final event):
          onLifecycle?.call(hostId, event);
        case HookMessage(:final hook):
          onHook?.call(hostId, hook);
        default:
          break;
      }
    });
    try {
      await link.watch();
    } on BoxLinkException catch (error) {
      _log('${host.name}: its host would not be watched ($error)');
    }
    return link;
  }

  /// Starts [sessionId] on [hostId] and keeps its screen — or, when the box
  /// already runs it, keeps the one there (`adopted`). Throws
  /// [BoxUnavailable] in words.
  Future<({BoxScreen screen, bool adopted})> openOn(
    String hostId, {
    required String sessionId,
    required List<String> argv,
    String? workingDirectory,
    Map<String, String> environment = const {},
    Set<String> removedEnvironment = const {},
    required int columns,
    required int rows,
  }) async {
    final ref = boxSessionRef(hostId, sessionId);
    final known = _screens[ref];
    if (known != null && !known.lifecycle.hasEnded && known.linked) {
      return (screen: known, adopted: true);
    }
    final link = await this.link(hostId);
    BoxRoute route;
    var adopted = false;
    try {
      route = await link.open(
        sessionId: sessionId,
        argv: argv,
        workingDirectory: workingDirectory,
        environment: environment,
        removedEnvironment: removedEnvironment,
        columns: columns,
        rows: rows,
      );
    } on BoxLinkException catch (error) {
      if (error.code == ProtocolErrorCode.sessionExists) {
        // Running there already — started by this server before it
        // restarted, or by another: kept, never started twice.
        route = await link.attach(sessionId: sessionId);
        adopted = true;
      } else {
        throw BoxUnavailable(
          '${_host(hostId).name} would not start it: $error',
        );
      }
    }
    return (screen: _keep(hostId, sessionId, route), adopted: adopted);
  }

  BoxScreen _keep(String hostId, String sessionId, BoxRoute route) {
    final ref = boxSessionRef(hostId, sessionId);
    final previous = _screens[ref];
    // An ended record under the same id is replaced, as the registry does.
    if (previous != null && !previous.lifecycle.hasEnded) {
      previous.follow(route);
      return previous;
    }
    previous?.dispose();
    final attached = route.attached;
    final screen = BoxScreen(
      hostId: hostId,
      id: sessionId,
      startedAt: attached.observedAt,
      columns: attached.columns,
      rows: attached.rows,
    )..follow(route);
    _screens[ref] = screen;
    _aliases[sessionId] = hostId;
    return screen;
  }

  /// Keeps a copy of every session still running on [hostId] — after the
  /// server restarted, the box kept them. Throws [BoxUnavailable].
  Future<int> adoptRunning(String hostId) async {
    final link = await this.link(hostId);
    var adopted = 0;
    for (final summary in await link.list()) {
      if (summary.lifecycle.hasEnded) continue;
      final ref = boxSessionRef(hostId, summary.id);
      if (_screens[ref]?.linked ?? false) continue;
      try {
        _keep(hostId, summary.id, await link.attach(sessionId: summary.id));
        adopted++;
      } on BoxLinkException catch (error) {
        _log('${summary.id} on $hostId could not be kept: $error');
      }
    }
    return adopted;
  }

  /// Every session [hostId]'s host holds, ended ones included.
  Future<List<SessionSummary>> boxSessions(String hostId) async =>
      (await link(hostId)).list();

  ({String hostId, String sessionId})? resolve(String sessionId) {
    final named = parseBoxSessionRef(sessionId);
    if (named != null) return named;
    final hostId = _aliases[sessionId];
    return hostId == null ? null : (hostId: hostId, sessionId: sessionId);
  }

  Future<BoxRoute> attach({
    required String hostId,
    required String sessionId,
    required int sinceOffset,
    (int, int)? screenGrid,
  }) async {
    final link = await this.link(hostId);
    final route = await link.attach(
      sessionId: sessionId,
      sinceOffset: sinceOffset,
      screenGrid: screenGrid,
    );
    // A pane on a session this server did not start (a restore after the
    // server restarted) is also kept, so its lifecycle is read here too.
    final ref = boxSessionRef(hostId, sessionId);
    if (!(_screens[ref]?.linked ?? false)) {
      unawaited(
        link
            .attach(sessionId: sessionId)
            .then(
              (own) => _keep(hostId, sessionId, own),
              onError: (Object _) {},
            ),
      );
    }
    return route;
  }

  WriteToken tokenOf(String hostId, String sessionId) =>
      _tokens[boxSessionRef(hostId, sessionId)] ??= WriteToken();

  void resized(String hostId, String sessionId, int columns, int rows) =>
      _screens[boxSessionRef(hostId, sessionId)]?.resized(columns, rows);

  /// Ends [sessionId] on [hostId] for good; its exit code, when it had one.
  Future<int?> closeOn(
    String hostId,
    String sessionId, {
    int signal = 15,
  }) async {
    final code = await (await link(
      hostId,
    )).closeSession(sessionId, signal: signal);
    final ref = boxSessionRef(hostId, sessionId);
    _screens[ref]?.endedWithoutWord('closed on request');
    _tokens.remove(ref);
    return code;
  }

  void forgetClient(String clientId) {
    for (final token in _tokens.values) {
      token.releaseIfHeldBy(clientId);
    }
  }

  /// Hangs up on [hostId]: the box keeps its sessions; the server's copies
  /// wait for the next link.
  Future<void> disconnect(String hostId) async {
    final opening = _links.remove(hostId);
    if (opening == null) return;
    try {
      await (await opening).close();
    } on Object {
      // Never opened: nothing to hang up.
    }
  }

  void _linkLost(String hostId, BoxLink link, String why) {
    if (_links[hostId] case final current?) {
      unawaited(
        current.then((open) {
          if (identical(open, link)) _links.remove(hostId);
        }, onError: (Object _) {}),
      );
    }
    if (_closed) return;
    final waiting = [
      for (final screen in _screens.values)
        if (screen.hostId == hostId && !screen.lifecycle.hasEnded) screen,
    ];
    if (waiting.isEmpty) return;
    _log(
      'the link to $hostId dropped ($why); ${waiting.length} session(s) wait',
    );
    unawaited(_relink(hostId));
  }

  /// Links again with a widening delay while any of [hostId]'s sessions is
  /// running, and puts each copy back on it from where it stopped.
  Future<void> _relink(String hostId) async {
    if (!_relinking.add(hostId)) return;
    try {
      var attempt = 0;
      while (!_closed) {
        await Future<void>.delayed(
          relinkDelays[attempt < relinkDelays.length
              ? attempt
              : relinkDelays.length - 1],
        );
        attempt++;
        if (_closed) return;
        final waiting = [
          for (final screen in _screens.values)
            if (screen.hostId == hostId &&
                !screen.lifecycle.hasEnded &&
                !screen.linked)
              screen,
        ];
        if (waiting.isEmpty) return;
        final BoxLink link;
        try {
          link = await this.link(hostId);
        } on Object catch (error) {
          _log('$hostId: not linked again yet ($error)');
          continue;
        }
        for (final screen in waiting) {
          try {
            screen.follow(
              await link.attach(
                sessionId: screen.id,
                sinceOffset: screen.nextOffset,
              ),
            );
          } on BoxLinkException catch (error) {
            if (error.code == ProtocolErrorCode.unknownSession) {
              screen.endedWithoutWord(
                'the host on the box no longer holds it — it was restarted',
              );
            }
          }
        }
        return;
      }
    } finally {
      _relinking.remove(hostId);
    }
  }

  // --- What the rest of the server uses (`RemoteSessions`) ---

  @override
  bool reaches(ExecutionEnvironment environment) =>
      refusal == null &&
      environment.kind == EnvironmentKind.ssh &&
      environment.sshHostId != null &&
      _hostOf(environment.sshHostId!) != null;

  @override
  Future<({RemoteSession session, bool adopted})> open(
    ExecutionEnvironment environment, {
    required String sessionId,
    List<String>? argv,
    String? workingDirectory,
    Map<String, String> variables = const {},
    Set<String> removedVariables = const {},
    required int columns,
    required int rows,
  }) async {
    final hostId = environment.sshHostId;
    if (environment.kind != EnvironmentKind.ssh || hostId == null) {
      throw RemoteSessionRefused('${environment.name} is not an SSH machine.');
    }
    try {
      // Linked first: a box that cannot run the host is refused before
      // anything is asked of it.
      await link(hostId);
      final shell = argv == null ? await loginShell(hostId) : null;
      final opened = await openOn(
        hostId,
        sessionId: sessionId,
        // The host spawns exactly this argv, so a shell names the box
        // user's own login shell: `/bin/sh` is what nobody chose.
        argv: argv ?? [shell ?? '/bin/sh', '-l'],
        workingDirectory: workingDirectory,
        environment: {'TERM': 'xterm-256color', ...variables},
        removedEnvironment: removedVariables,
        columns: columns,
        rows: rows,
      );
      return (session: opened.screen as RemoteSession, adopted: opened.adopted);
    } on BoxUnavailable catch (error) {
      throw RemoteSessionRefused(error.message);
    }
  }

  @override
  RemoteSession? byId(String sessionId) => screenById(sessionId);

  @override
  Iterable<RemoteSession> get sessions => _screens.values;

  @override
  Future<int?> close(String sessionId) async {
    final box = resolve(sessionId);
    if (box == null) {
      throw RemoteSessionRefused('no session "$sessionId" on an SSH box');
    }
    try {
      return await closeOn(box.hostId, box.sessionId);
    } on BoxUnavailable catch (error) {
      throw RemoteSessionRefused(error.message);
    } on BoxLinkException catch (error) {
      throw RemoteSessionRefused(error.message);
    }
  }

  /// Hangs up on every box and lets go of every copy. The boxes keep their
  /// sessions.
  Future<void> dispose() async {
    _closed = true;
    for (final screen in _screens.values) {
      screen.dispose();
    }
    for (final opening in _links.values.toList()) {
      try {
        await (await opening).close();
      } on Object {
        // Never opened: nothing to hang up.
      }
    }
    _links.clear();
    for (final access in _access.values) {
      await access.dispose();
    }
    _access.clear();
  }
}
