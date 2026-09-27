import 'dart:async';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart' show PathProbe;
import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart' show CliStoreLocator;
import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_checkpoints/store.dart' show CheckpointDao;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart' show DataService;
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/automations/daemon_checkout_facts.dart';
import 'package:karmashala_host/src/automations/hosted_agent_launcher.dart';
import 'package:karmashala_host/src/data/conversations_handler.dart'
    show TranscriptStores;
import 'package:karmashala_host/src/mcp/tools/checkout_reach.dart';
import 'package:karmashala_host/src/mcp/tools/continuation_tool_set.dart';
import 'package:karmashala_host/src/mcp/tools/server_tool_context.dart';
import 'package:karmashala_host/src/sessions/launch/server_session_launcher.dart';
import 'package:karmashala_host/src/sessions/launch/session_continuations.dart';
import 'package:karmashala_session/lineage.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

final class _Everywhere implements PathProbe {
  const _Everywhere();
  @override
  bool? fileExists(String path) => true;
  @override
  bool isLink(String path) => false;
  @override
  String? linkTarget(String path) => null;
}

/// Slice 5b: `session_handoff`, `session_fork` and
/// `session_fork_from_checkpoint` run in the server; the new session is
/// shown in the window a person last used, or the answer says none is open.
void main() {
  final t0 = DateTime.utc(2026, 9, 27, 12);
  final local = Platform.isWindows ? 'windowsNative' : 'localPosix';

  late AppDatabase database;
  late SessionRegistry registry;
  late FakePtyLauncher pty;
  late ServerToolContext context;
  late ContinuationToolSet tools;
  var ids = 0;

  setUp(() {
    ids = 0;
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    database.execute(
      'INSERT INTO execution_environments (id, kind, name, created_at) '
      'VALUES (?, ?, ?, ?);',
      ['local', local, 'Here', '$t0'],
    );
    database.execute(
      'INSERT INTO repositories (id, project_id, name, environment_id, path, '
      'created_at) VALUES (?, ?, ?, ?, ?, ?);',
      ['r1', 'p1', 'shop-api', 'local', '/src/shop/api', '$t0'],
    );
    database.execute(
      'INSERT INTO agent_installations (id, agent_kind, environment_id, '
      'executable_path, created_at, executable_by_user) '
      'VALUES (?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?);',
      [
        'a1', AgentIds.claudeCode, 'local', '/bin/claude', '$t0', 1, //
        'c1', AgentIds.codex, 'local', '/bin/codex', '$t0', 1,
      ],
    );
    SessionDao(database).insert(
      Session(
        id: 's1',
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'Cart',
        useWorktree: false,
        status: SessionStatus.completed,
        createdAt: t0,
        externalSessionId: 'conv-1',
      ),
    );
    pty = FakePtyLauncher();
    registry = SessionRegistry(launcher: pty);
    final data = DataService(database, clock: () => t0);
    context = ServerToolContext(
      database: database,
      data: data,
      dataDirectory: '/nowhere',
      clock: () => t0,
    );
    final rows = CheckoutRows(database);
    final launches = ServerSessionLauncher(
      launcher: HostedAgentLauncher(
        registry: registry,
        sessions: SessionDao(database),
        mcp: SessionMcpAccessPoint(mcp: null, configDirectory: '/nowhere'),
        now: () => t0,
        newId: () => 'new-${++ids}',
        hostEnvironment: const {},
        environmentOf: rows.environment,
      ),
      registry: registry,
      sessions: SessionDao(database),
      rows: rows,
      facts: DaemonCheckoutFacts(rows, windows: Platform.isWindows),
      installationsIn: data.installationsIn,
      pathProbe: const _Everywhere(),
      directoryPresent: (_) => true,
    );
    tools = ContinuationToolSet(
      context,
      continuations: SessionContinuations(
        launches: launches,
        sessions: SessionDao(database),
        rows: rows,
        decisions: DecisionRecordDao(database),
        checkpoints: CheckpointDao(database),
        reach: CheckoutReach(database),
        transcripts: TranscriptStores(
          locator: CliStoreLocator(
            runnerFor: (_) => const CommandRunnerFactory().forEnvironment(
              localHostEnvironment(t0),
            ),
          ),
          environments: () => const [],
        ),
        carryDecision: (_) {},
      ),
    );
  });

  tearDown(() async {
    context.close();
    for (final handle in pty.handles) {
      handle.finish(0);
    }
    await registry.shutdown();
    database.close();
  });

  Future<Map<String, Object?>> call(
    String tool,
    Map<String, dynamic> args,
  ) async =>
      (await tools.call(tool, args, null)!.timeout(const Duration(seconds: 10)))
          as Map<String, Object?>;

  group('session_handoff', () {
    test('preview picks another agent and starts nothing', () async {
      final answer = await call('session_handoff', {
        'sessionId': 's1',
        'instruction': 'finish it',
        'preview': true,
      });
      expect(answer['preview'], isTrue);
      expect(answer['target'], contains('Codex'));
      expect(answer['packet'], contains('finish it'));
      expect(pty.started, isEmpty);
    });

    test('an instruction is required', () async {
      await expectLater(
        tools.call('session_handoff', {'sessionId': 's1'}, null),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a cli nobody installed is refused, never another agent', () async {
      await expectLater(
        tools.call('session_handoff', {
          'sessionId': 's1',
          'instruction': 'x',
          'cli': 'antigravity',
        }, null),
        throwsA(isA<StateError>()),
      );
      expect(pty.started, isEmpty);
    });

    test('starts the continuation, and says no window is open', () async {
      final answer = await call('session_handoff', {
        'sessionId': 's1',
        'instruction': 'finish it',
        'cli': 'codex',
      });
      expect(answer['link'], SessionLink.handoff.name);
      expect(answer['parentSessionId'], 's1');
      expect(answer['where'], contains('no Karmashala window is open'));
      expect(pty.started, hasLength(1));
    });

    test('a window is asked to show the continuation', () async {
      final told = <DataChange>[];
      context.data
          .open((batch) => told.addAll(batch.changes))
          .handle(const DataSubscribe());
      final answer = await call('session_handoff', {
        'sessionId': 's1',
        'instruction': 'finish it',
        'cli': 'codex',
      });
      expect(
        told.whereType<OpenSessionTab>().single.sessionId,
        answer['sessionId'],
      );
    });
  });

  group('session_fork', () {
    test('preview names the route and starts nothing', () async {
      final answer = await call('session_fork', {
        'sessionId': 's1',
        'preview': true,
      });
      expect(answer['route'], 'native');
      expect(pty.started, isEmpty);
    });

    test('a fork runs the same agent as a fork of the conversation', () async {
      final answer = await call('session_fork', {'sessionId': 's1'});
      expect(answer['link'], SessionLink.fork.name);
      expect(pty.started.single.argv, contains('--fork-session'));
      expect(answer['where'], contains('no Karmashala window is open'));
    });
  });

  test('session_fork_from_checkpoint names its session', () async {
    await expectLater(
      tools.call('session_fork_from_checkpoint', {'turn': 1}, null),
      throwsA(isA<ArgumentError>()),
    );
  });
}
