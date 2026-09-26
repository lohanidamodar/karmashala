import 'dart:async';
import 'dart:io';

import 'package:karmashala_host/lifecycle_client.dart';
import 'package:karmashala_notes/karmashala_notes.dart';
import 'package:karmashala_notes/store.dart';
import 'package:karmashala_remote/client.dart';
import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_store/database.dart';

/// The pieces a live companion test drives a real `karmashala_host serve`
/// with: the store the app would have written, the app's own lifecycle link,
/// and a phone on loopback built from the phone's own pairing and session
/// clients. Nothing here stands in for the host.

/// The row, notes and todo the test seeds, by the names it asserts on.
const String seededSessionId = 'live-s1';
const String seededSessionTitle = 'Fix the cart';
const String seededNote = 'Try a compact tab strip';
const String seededTodo = 'Ship the fix';

/// A second row, whose installation is Claude Code's: the daemon keeps its
/// agent's status off the screen the test's fake agent draws.
const String seededAgentSessionId = 'live-agent';

/// The installation a phone starts sessions with: Claude Code's adapter over a
/// stand-in script ([fakeAgentPath]) that says what it was started with, reads
/// one line, says it back and exits 0.
const String fakeAgentInstallationId = 'a3';

/// Where [seedStore] writes the stand-in agent, under the test's home.
String fakeAgentPath(Directory dataDir) => '${dataDir.parent.path}/fake-agent';

/// Seeds `<dataDir>/karmashala.sqlite` the way the app and agent discovery
/// would have left it — this machine's environment, a project, a repository,
/// session rows not yet started, agent installations (one a stand-in script),
/// a note and a todo — and closes it again before the host opens the file.
/// Its `server.json` has remote access on, as the desktop's switch leaves it
/// (on loopback, no beacon: a test multicasts nothing).
void seedStore(Directory dataDir) {
  dataDir.createSync(recursive: true);
  File(
    '${dataDir.path}/server.json',
  ).writeAsStringSync('{"companion": {"enabled": true}}\n');
  Process.runSync('chmod', ['600', '${dataDir.path}/server.json']);
  final database = AppDatabase.open(dataDir);
  try {
    final t0 = DateTime.now().toUtc();
    // The agent installation the row names is the app's; no FK chase here.
    database.execute('PRAGMA foreign_keys = OFF;');
    database.execute(
      'INSERT INTO projects (id, name, root_environment_id, root_path, '
      'created_at) VALUES (?, ?, ?, ?, ?);',
      ['p1', 'Shop', 'local', dataDir.path, t0.toIso8601String()],
    );
    database.execute(
      'INSERT INTO repositories (id, project_id, name, environment_id, path, '
      'created_at) VALUES (?, ?, ?, ?, ?, ?);',
      ['r1', 'p1', 'shop-api', 'local', dataDir.path, t0.toIso8601String()],
    );
    SessionDao(database).insert(
      Session(
        id: seededSessionId,
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: seededSessionTitle,
        useWorktree: false,
        status: SessionStatus.created,
        createdAt: t0,
      ),
    );
    // This machine, as agent discovery records it.
    database.execute(
      'INSERT INTO execution_environments (id, kind, name, created_at) '
      'VALUES (?, ?, ?, ?);',
      ['local', 'localPosix', 'This machine', t0.toIso8601String()],
    );
    database.execute(
      'INSERT INTO agent_installations (id, agent_kind, environment_id, '
      'executable_path, created_at, executable_by_user) '
      'VALUES (?, ?, ?, ?, ?, ?);',
      ['a2', 'claudeCode', 'local', '/usr/bin/claude', t0.toIso8601String(), 1],
    );
    final agent = File(fakeAgentPath(dataDir))
      ..writeAsStringSync(
        '#!/bin/sh\n'
        // One argument a line, so a long path wrapping cannot split one.
        'echo FAKE-AGENT\n'
        'for arg in "\$@"; do echo "\$arg"; done\n'
        'read -r line\n'
        'echo "FAKE-GOT<\$line>"\n'
        'exit 0\n',
      );
    Process.runSync('chmod', ['+x', agent.path]);
    database.execute(
      'INSERT INTO agent_installations (id, agent_kind, environment_id, '
      'executable_path, created_at, executable_by_user) '
      'VALUES (?, ?, ?, ?, ?, ?);',
      [
        fakeAgentInstallationId,
        'claudeCode',
        'local',
        agent.path,
        t0.add(const Duration(seconds: 1)).toIso8601String(),
        1,
      ],
    );
    SessionDao(database).insert(
      Session(
        id: seededAgentSessionId,
        repositoryId: 'r1',
        agentInstallationId: 'a2',
        title: 'Create the note',
        useWorktree: false,
        status: SessionStatus.created,
        createdAt: t0.add(const Duration(seconds: 1)),
      ),
    );
    NoteDao(database).insert(
      Note(
        id: 'n1',
        body: seededNote,
        projectId: 'p1',
        createdAt: t0,
        updatedAt: t0,
      ),
    );
    TodoDao(
      database,
    ).insert(Todo(id: 't1', body: seededTodo, position: 0, createdAt: t0));
  } finally {
    database.close();
  }
}

/// Where the daemon's phone listener bound, as its greeting says it.
int companionPortOf(String greeting) {
  final match = RegExp(r'companion on port (\d+)').firstMatch(greeting);
  if (match == null) {
    throw StateError('the host did not say it serves phones:\n$greeting');
  }
  return int.parse(match.group(1)!);
}

/// The desktop app's side of the companion, over the same lifecycle link the
/// app opens (`LocalHostLifecycleSource` → `HostLifecycleWatch`): the attach
/// it sends on every link, the pairing it asks for, and the calls the host
/// forwards to it.
class AppLink {
  AppLink._(this.watch);

  final HostLifecycleWatch watch;

  /// Calls nobody has taken yet, oldest first, and who waits for which method.
  final _unanswered = <CompanionCallMessage>[];
  final _waiting = <String, Completer<CompanionCallMessage>>{};

  /// Methods answered the moment they arrive, as the app answers them without
  /// anybody looking: the host asks the app's view of the sessions whenever it
  /// re-sweeps phones.
  final _standing = <String, Map<String, Object?>>{};

  /// A link that is the app when [asApp]: it attaches as
  /// `HostCompanionLink.attached` does. Otherwise it only watches — a `pair`
  /// over SSH, which is not the app and must not be adopted as it.
  static Future<AppLink> connect(
    String socketPath, {
    bool asApp = false,
  }) async {
    final watch = await HostLifecycleWatch.connect(socketPath);
    if (watch == null) throw StateError('no host at $socketPath');
    final link = AppLink._(watch);
    watch.companionCalls.listen(link._onCall);
    if (asApp) watch.attachCompanion();
    return link;
  }

  void _onCall(CompanionCallMessage call) {
    final standing = _standing[call.method];
    if (standing != null) return answer(call.callId, standing);
    final waiting = _waiting.remove(call.method);
    if (waiting != null) return waiting.complete(call);
    _unanswered.add(call);
  }

  /// Opens a pairing window granting [capabilities], direct (no relay), as the
  /// pairing dialog does for a machine with no relay configured.
  Future<PairingPayload> pair(CapabilitySet capabilities) async {
    final window = await watch.pairCompanion(capabilities: capabilities.bits);
    return PairingPayload.decode(window.payload);
  }

  /// Answers every call of [method], now and from now on, with [result].
  void answerAlways(String method, Map<String, Object?> result) {
    _standing[method] = result;
    for (final call in _unanswered.where((c) => c.method == method).toList()) {
      _unanswered.remove(call);
      answer(call.callId, result);
    }
  }

  /// The next forwarded call of [method].
  Future<CompanionCallMessage> nextCall(
    String method, {
    Duration within = const Duration(seconds: 20),
  }) {
    final index = _unanswered.indexWhere((c) => c.method == method);
    if (index >= 0) return Future.value(_unanswered.removeAt(index));
    final waiting = _waiting[method] = Completer<CompanionCallMessage>();
    return waiting.future.timeout(
      within,
      onTimeout: () {
        _waiting.remove(method);
        throw TimeoutException('the host forwarded no $method', within);
      },
    );
  }

  void answer(int callId, Map<String, Object?> result) =>
      watch.answerCompanionCall(callId, result: result);

  /// News from the desktop, as `HostCompanionLink.notice` sends it.
  void notice(CompanionNoticeMessage notice) => watch.noticeCompanion(notice);

  Future<void> close() => watch.close();
}

/// A phone on loopback: the phone's real pairing client over a LAN transport
/// to the daemon's listener, then its real session client on the pairing it
/// stored. The only thing the phone app adds on top — the beacon/relay race —
/// is replaced by naming the listener outright.
class LoopbackPhone {
  LoopbackPhone(this.port, {required this.name});

  /// Where it dials: a server whose listener moved is dialled at the new port
  /// with the same pairing.
  int port;
  final String name;
  final store = InMemoryCompanionStore();
  CompanionPairing? pairing;

  Future<CompanionPairing> pair(PairingPayload payload) async {
    final transport = LanTransport(host: '127.0.0.1', port: port)..start();
    try {
      return pairing = await CompanionPairingClient(
        store: store,
        deviceName: name,
      ).pair(payload, transport: transport);
    } finally {
      await transport.close();
    }
  }

  /// A sealed session connection at the stored record's next generation.
  Future<CompanionClient> dial() async {
    final paired = pairing;
    if (paired == null) throw StateError('$name has not paired');
    final client = CompanionClient(pairing: paired, store: store);
    await client.connect(
      transport: LanTransport(host: '127.0.0.1', port: port)..start(),
      helloTimeout: const Duration(seconds: 10),
    );
    // The next link dials the generation after this one, as the phone's
    // stored record would: a generation is never dialled twice.
    pairing = client.pairing;
    return client;
  }
}

/// Asks [read] until [done] holds or [within] runs out, returning the last
/// answer. For the screen transcript alone, which keeps a new screen at most
/// every few seconds by design; everything else in these tests is awaited on
/// the event that settles it.
Future<T> readUntil<T>(
  Future<T> Function() read,
  bool Function(T value) done, {
  Duration within = const Duration(seconds: 20),
  Duration every = const Duration(milliseconds: 500),
}) async {
  final deadline = DateTime.now().add(within);
  var value = await read();
  while (!done(value) && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(every);
    value = await read();
  }
  return value;
}
