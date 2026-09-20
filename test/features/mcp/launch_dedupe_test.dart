import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala_mcp/launch.dart';
import 'package:karmashala/src/features/mcp/launcher_control_server.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_local_ipc/karmashala_local_ipc.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:path/path.dart' as p;

import '../../support/fixtures.dart';

/// A clock the test moves, because the whole question the window answers is
/// "how long ago was this asked".
class _MovingClock implements Clock {
  DateTime now = testTime;
  @override
  DateTime nowUtc() => now;
}

/// The launcher, replaced by something that is slow on demand and counts.
///
/// Only [launch] is overridden: everything else `open_new_session` asks the
/// launcher — the depth cap, the default installation — is the real answer.
class _CountingLauncher extends SessionLauncher {
  _CountingLauncher(super.ref, this.gate);

  final Completer<void> gate;
  int launches = 0;

  @override
  Future<SessionLaunchResult> launch(
    SessionLaunchRequest request, {
    SystemTerminal? externalTerminal,
  }) async {
    launches++;
    // Stands in for creating a worktree on `/mnt/c`: the part of a launch that
    // outlasts the caller's patience.
    await gate.future;
    return SessionLaunchResult(
      session: session(id: 'launched-$launches', title: request.title),
    );
  }
}

void main() {
  group('which tools a retry must not repeat', () {
    test('the four that start an agent, and no others', () {
      for (final tool in [
        'open_new_session',
        'open_sessions_in_tmux',
        'session_handoff',
        'session_fork',
      ]) {
        expect(startsAnAgent(tool, const {}), isTrue, reason: tool);
      }
      for (final tool in [
        'list_sessions',
        'list_projects',
        'open_session',
        'session_send',
        'note_add',
      ]) {
        expect(startsAnAgent(tool, const {}), isFalse, reason: tool);
      }
    });

    test('a preview starts nothing, so it is not one', () {
      expect(startsAnAgent('session_handoff', {'preview': true}), isFalse);
      expect(startsAnAgent('session_fork', {'preview': true}), isFalse);
      expect(startsAnAgent('session_fork', {'preview': false}), isTrue);
    });
  });

  group('the fingerprint', () {
    test('is the whole request, not a chosen few fields', () {
      final base = {'projectId': 'p1', 'prompt': 'audit', 'title': 't'};
      final key = launchFingerprint('open_new_session', base, 'caller-1');
      // Every one of these is a different request.
      expect(
        launchFingerprint('open_new_session', base, 'caller-2'),
        isNot(key),
      );
      expect(launchFingerprint('session_fork', base, 'caller-1'), isNot(key));
      expect(
        launchFingerprint('open_new_session', {
          ...base,
          'prompt': 'audit ',
        }, 'caller-1'),
        isNot(key),
      );
      expect(
        launchFingerprint('open_new_session', {
          ...base,
          'useWorktree': true,
        }, 'caller-1'),
        isNot(key),
      );
    });

    test('does not depend on the order the arguments arrived in', () {
      expect(
        launchFingerprint('open_new_session', {
          'projectId': 'p1',
          'prompt': 'audit',
        }, null),
        launchFingerprint('open_new_session', {
          'prompt': 'audit',
          'projectId': 'p1',
        }, null),
      );
    });

    test('reaches into nested values', () {
      expect(
        launchFingerprint('open_sessions_in_tmux', {
          'ids': ['a', 'b'],
        }, null),
        isNot(
          launchFingerprint('open_sessions_in_tmux', {
            'ids': ['b', 'a'],
          }, null),
        ),
      );
    });
  });

  group('the ledger', () {
    late _MovingClock clock;
    late LaunchDedupe dedupe;
    late List<String> collapsed;

    setUp(() {
      clock = _MovingClock();
      collapsed = [];
      dedupe = LaunchDedupe(clock: clock, onCollapsed: collapsed.add);
    });

    Future<Object?> open(
      Future<Object?> Function() start, {
      String prompt = 'audit',
      String? caller = 'caller-1',
    }) => dedupe.run(
      tool: 'open_new_session',
      arguments: {'projectId': 'p1', 'prompt': prompt},
      callerSessionId: caller,
      start: start,
    );

    test('a repeat that arrives mid-flight gets the first call, not a '
        'second launch', () async {
      // The incident: the retry landed 55s in, while the first launch was still
      // making its worktree, so nothing had been *recorded* yet.
      final gate = Completer<Object?>();
      var launches = 0;
      Future<Object?> launch() {
        launches++;
        return gate.future;
      }

      final first = open(launch);
      final retry = open(launch);
      expect(launches, 1);

      gate.complete({'sessionId': '8a8ef8ed'});
      expect(await first, {'sessionId': '8a8ef8ed'});
      expect(await retry, {'sessionId': '8a8ef8ed'});
      expect(launches, 1);
      expect(collapsed, ['open_new_session']);
    });

    test('a repeat inside the window gets the session already open', () async {
      var launches = 0;
      Future<Object?> launch() async => {'sessionId': 's${++launches}'};

      expect(await open(launch), {'sessionId': 's1'});
      clock.now = clock.now.add(const Duration(seconds: 90));
      expect(await open(launch), {'sessionId': 's1'});
      expect(launches, 1);
    });

    test('past the window it is a new request again', () async {
      var launches = 0;
      Future<Object?> launch() async => {'sessionId': 's${++launches}'};

      expect(await open(launch), {'sessionId': 's1'});
      clock.now = clock.now.add(
        launchDedupeWindow + const Duration(seconds: 1),
      );
      expect(await open(launch), {'sessionId': 's2'});
      expect(launches, 2);
    });

    test('the window runs from when the launch finished, not when it '
        'started', () async {
      var launches = 0;
      final gate = Completer<Object?>();
      Future<Object?> launch() {
        launches++;
        return gate.future;
      }

      final first = open(launch);
      // A launch slower than the whole window is still one launch.
      clock.now = clock.now.add(const Duration(minutes: 5));
      gate.complete({'sessionId': 's1'});
      await first;

      clock.now = clock.now.add(const Duration(seconds: 30));
      expect(await open(launch), {'sessionId': 's1'});
      expect(launches, 1);
    });

    test('a different caller, or a different prompt, is a different '
        'request', () async {
      var launches = 0;
      Future<Object?> launch() async => {'sessionId': 's${++launches}'};

      expect(await open(launch), {'sessionId': 's1'});
      expect(await open(launch, caller: 'caller-2'), {'sessionId': 's2'});
      expect(await open(launch, prompt: 'something else'), {'sessionId': 's3'});
      expect(collapsed, isEmpty);
    });

    test('a failure is shared while in flight and forgotten after', () async {
      var launches = 0;
      final gate = Completer<Object?>();
      Future<Object?> launch() {
        launches++;
        return gate.future;
      }

      final first = open(launch);
      final retry = open(launch);
      gate.completeError(StateError('no agent is installed'));
      await expectLater(first, throwsStateError);
      await expectLater(retry, throwsStateError);
      expect(launches, 1);

      // Nothing survived that launch, so the next call must genuinely try
      // again rather than be handed two minutes of the same wrong answer.
      expect(await open(() async => {'sessionId': 's1'}), {'sessionId': 's1'});
    });
  });

  group('open_new_session over the owner-only socket', () {
    late Directory tmp;
    late AppDatabase db;
    late ProviderContainer container;
    late LauncherControlServer server;
    late Completer<void> gate;
    late _CountingLauncher launcher;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('karmashala_launch_dedupe_');
      db = AppDatabase.memory();
      addTearDown(db.close);
      ExecutionEnvironmentDao(db).upsert(windowsEnv());
      ProjectDao(db).insert(project());
      RepositoryDao(db).insert(repository());
      AgentInstallationDao(db).insert(agentInstallation());
      gate = Completer<void>();
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          sessionLauncherProvider.overrideWith((ref) {
            return launcher = _CountingLauncher(ref, gate);
          }),
        ],
      );
      server = LauncherControlServer(container);
      await server.start(
        bridgeFilePath: p.join(tmp.path, 'mcp_bridge.json'),
        socketDirectory: p.join(tmp.path, 'ipc'),
      );
    });

    tearDown(() async {
      if (!gate.isCompleted) gate.complete();
      await server.stop();
      container.dispose();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    Future<Object?> call(String tool, Map<String, Object?> args) async {
      final handshake =
          jsonDecode(
                File(p.join(tmp.path, 'mcp_bridge.json')).readAsStringSync(),
              )
              as Map<String, Object?>;
      final raw = await LocalRpcClient.call(
        handshake['socketPath']! as String,
        jsonEncode({
          'tool': tool,
          'arguments': args,
          'token': handshake['token'],
        }),
      );
      final decoded = jsonDecode(raw) as Map<String, Object?>;
      if (decoded['ok'] != true) throw StateError('${decoded['error']}');
      return decoded['result'];
    }

    test('two identical calls start one agent and get one answer', () async {
      const args = {
        'projectId': 'p1',
        'agentInstallationId': 'a1',
        'title': 'codex perf audit',
        'prompt': 'audit the terminal',
      };
      final first = call('open_new_session', args);
      final retry = call('open_new_session', args);
      // Nothing has returned yet — this is the state the real retry arrived in.
      gate.complete();

      final a = (await first)! as Map<String, Object?>;
      final b = (await retry)! as Map<String, Object?>;
      expect(launcher.launches, 1);
      expect(a['sessionId'], 'launched-1');
      expect(b, a);
    });

    test('a different prompt is still a second session', () async {
      gate.complete();
      final a =
          (await call('open_new_session', {
                'projectId': 'p1',
                'agentInstallationId': 'a1',
                'prompt': 'one',
              }))!
              as Map<String, Object?>;
      final b =
          (await call('open_new_session', {
                'projectId': 'p1',
                'agentInstallationId': 'a1',
                'prompt': 'two',
              }))!
              as Map<String, Object?>;
      expect(launcher.launches, 2);
      expect(a['sessionId'], isNot(b['sessionId']));
    });

    test('a read answers freshly every time', () async {
      expect(await call('list_sessions', const {}), isEmpty);
      SessionDao(db).insert(session());
      // The ledger must not be in the way of a read: the identical call, made
      // a moment later, has to see what changed in between.
      expect(await call('list_sessions', const {}), hasLength(1));
    });
  });
}
