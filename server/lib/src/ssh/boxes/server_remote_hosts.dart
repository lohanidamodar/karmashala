import 'dart:async';

import 'package:agent_cli/process.dart';
import 'package:karmashala_host_protocol/protocol.dart';
import 'package:karmashala_ssh/connection.dart';
import 'package:karmashala_ssh_host/host.dart';

import '../../domain/write_token.dart';
import 'box_screen.dart';
import 'remote_sessions.dart';

/// A box the server cannot use right now: [message] short enough for a pane,
/// [detail] the technical account behind it, for the log and Details.
class BoxUnavailable implements Exception {
  const BoxUnavailable(
    this.message, {
    this.detail,
    this.deployment,
    this.nothingThere = false,
  });

  final String message;
  final String? detail;

  /// The deploy that did not end ready, when that is why.
  final HostDeployment? deployment;

  /// Nothing on the box can hold the session asked for: no host runs there
  /// (and none was started, since only looking was allowed), or the box is
  /// not one this server uses. A pane attaching shows its session ended.
  final bool nothingThere;

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
      (throw BoxUnavailable(
        'No SSH machine is saved as $hostId.',
        nothingThere: true,
      ));

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

  /// The one link to [hostId]'s host, deployed — installed, started — first
  /// if need be: for an explicit start (`terminals.open`, a launch, a run).
  /// Throws [BoxUnavailable] in words when the box cannot run it.
  Future<BoxLink> link(String hostId) {
    if (_unusable() case final why?) return Future.error(why);
    final existing = _links[hostId];
    if (existing == null) return _register(hostId, _openLink(hostId));
    if (!_looking.contains(existing)) return existing;
    // A look in flight may find nothing running; a start deploys then.
    return existing.catchError((Object _) {
      if (identical(_links[hostId], existing)) _links.remove(hostId);
      return link(hostId);
    });
  }

  /// The link to [hostId]'s host **only if it already runs** — never
  /// deployed, installed or started: what attaching to a session (a restored
  /// pane, a reconnect) and adopting the box's sessions may do. Throws
  /// [BoxUnavailable] ([BoxUnavailable.nothingThere] when no host runs).
  Future<BoxLink> looked(String hostId) {
    if (_unusable() case final why?) return Future.error(why);
    final existing = _links[hostId];
    if (existing != null) return existing;
    final looking = _lookLink(hostId);
    _looking.add(looking);
    looking.then(
      (_) => _looking.remove(looking),
      onError: (Object _) => _looking.remove(looking),
    );
    return _register(hostId, looking);
  }

  /// The links in [_links] that only look.
  final _looking = <Future<BoxLink>>{};

  BoxUnavailable? _unusable() {
    if (refusal case final why?) {
      return BoxUnavailable(why, nothingThere: true);
    }
    if (_closed) return const BoxUnavailable('The server is stopping.');
    return null;
  }

  Future<BoxLink> _register(String hostId, Future<BoxLink> opening) {
    _links[hostId] = opening;
    opening.then(
      (link) => link.closed.then((why) => _linkLost(hostId, link, why)),
      onError: (Object _) {
        if (_links[hostId] == opening) _links.remove(hostId);
      },
    );
    return opening;
  }

  BoxUnavailable _unreachable(SshHost host, Object error) => BoxUnavailable(
    "Can't reach ${host.name}. Check that it's online, then Retry.",
    detail: '${host.address}: ${describeSshFailure(error)}',
  );

  Future<BoxLink> _lookLink(String hostId) async {
    final host = _host(hostId);
    final access = accessOf(hostId);
    final String? running;
    try {
      running = await access.runningHost();
    } on Object catch (error) {
      throw _unreachable(host, error);
    }
    if (running == null) {
      throw BoxUnavailable(
        'No Karmashala host is running on ${host.name}.',
        detail:
            'No Karmashala host is running on ${host.address}, so it holds no '
            'session. Attaching only looks: nothing was started there.',
        nothingThere: true,
      );
    }
    return _connect(hostId, host, access, running);
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
      throw _unreachable(host, error);
    }
    final remotePath = reading.remotePath;
    if (!reading.isReady || remotePath == null) {
      // Not kept: a Retry opens again, and what stopped this one — a bundle
      // not on the server yet, a box that could not unpack — may be fixed.
      access.forgetReading();
      final failure = HostDeployFailure(
        hostName: host.name,
        deployment: reading,
      );
      throw BoxUnavailable(
        failure.inShort,
        detail: '$failure',
        deployment: reading,
      );
    }
    return _connect(hostId, host, access, remotePath);
  }

  Future<BoxLink> _connect(
    String hostId,
    SshHost host,
    SshHostSessionAccess access,
    String remotePath,
  ) async {
    final BoxLink link;
    try {
      link = await BoxLink.connect(
        await access.exec('$remotePath attach'),
        hostId: hostId,
        clientId: clientId,
      );
    } on BoxLinkException catch (error) {
      access.forgetReading();
      throw BoxUnavailable(
        "Can't open a terminal on ${host.name}: its Karmashala host did not "
        'answer. Retry.',
        detail: 'The Karmashala host on ${host.address} ($remotePath): $error',
      );
    } on Object catch (error) {
      throw _unreachable(host, error);
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
        final host = _host(hostId);
        throw BoxUnavailable(
          "Can't open a terminal on ${host.name}: its Karmashala host would "
          'not start it.',
          detail: '${host.address} would not start $sessionId: $error',
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
  /// server restarted, the box kept them. Only looks: a box whose host is not
  /// running is left as it is. Throws [BoxUnavailable].
  Future<int> adoptRunning(String hostId) async {
    final link = await looked(hostId);
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

  /// Attaches to [sessionId] on [hostId]. **Only looks** ([looked]): a box
  /// whose host is not running holds no session, and attaching starts
  /// nothing — only an explicit open may deploy or start the host.
  Future<BoxRoute> attach({
    required String hostId,
    required String sessionId,
    required int sinceOffset,
    (int, int)? screenGrid,
  }) async {
    final BoxLink link;
    try {
      link = await looked(hostId);
    } on BoxUnavailable catch (error) {
      _said(error);
      rethrow;
    }
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

  /// The grid [sessionId] on [hostId] is drawn at, as the server's copy
  /// follows it; null when the server keeps no copy of it.
  (int, int)? gridOf(String hostId, String sessionId) =>
      _screens[boxSessionRef(hostId, sessionId)]?.grid;

  /// Ends [sessionId] on [hostId] for good; its exit code, when it had one.
  /// Only looks: a box whose host is not running holds nothing to end, and
  /// is not started to be told so.
  Future<int?> closeOn(
    String hostId,
    String sessionId, {
    int signal = 15,
  }) async {
    final ref = boxSessionRef(hostId, sessionId);
    final BoxLink link;
    try {
      link = await looked(hostId);
    } on BoxUnavailable catch (error) {
      if (error.nothingThere) {
        _screens[ref]?.endedWithoutWord('the host on the box is not running');
        _tokens.remove(ref);
      }
      rethrow;
    }
    final code = await link.closeSession(sessionId, signal: signal);
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
          // Only looks: a host that went with the box rebooting took its
          // sessions, and starting a fresh one brings none of them back.
          link = await looked(hostId);
        } on BoxUnavailable catch (error) {
          if (error.nothingThere) {
            for (final screen in waiting) {
              screen.endedWithoutWord('the host on the box is not running');
            }
            _log('$hostId: ${error.detail ?? error.message}');
            return;
          }
          _log('$hostId: not linked again yet (${error.detail ?? error})');
          continue;
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
      _said(error);
      throw RemoteSessionRefused(error.message, detail: error.detail);
    }
  }

  /// Logs [error]'s whole account: a pane shows only its short words.
  void _said(BoxUnavailable error) =>
      _log('ssh: ${error.message}${error.detail == null ? '' : ' (${error.detail})'}');

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
      throw RemoteSessionRefused(error.message, detail: error.detail);
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
