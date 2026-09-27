import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart' show PathProbe;
import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart' show CliStoreLocator;
import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:karmashala_checkpoints/store.dart' show CheckpointDao;
import 'package:karmashala_host/data.dart' show DataService;
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/automations/daemon_checkout_facts.dart';
import 'package:karmashala_host/src/automations/hosted_agent_launcher.dart';
import 'package:karmashala_host/src/data/conversations_handler.dart'
    show TranscriptStores;
import 'package:karmashala_host/src/mcp/tools/checkout_reach.dart';
import 'package:karmashala_host/src/sessions/launch/handoff_packet_files.dart';
import 'package:karmashala_host/src/sessions/launch/server_session_launcher.dart';
import 'package:karmashala_host/src/sessions/launch/session_continuations.dart';
import 'package:karmashala_session/events.dart';
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

/// Transcripts found where a test put them, with no store walked.
class _Transcripts extends TranscriptStores {
  _Transcripts(this.paths)
    : super(
        locator: CliStoreLocator(
          runnerFor: (_) => const CommandRunnerFactory().forEnvironment(
            localHostEnvironment(DateTime.utc(2026)),
          ),
        ),
        environments: () => const [],
      );

  final Map<String, String> paths;

  @override
  Future<String?> locate(String cli, String conversationId) async =>
      paths['$cli/$conversationId'];
}

/// Slice 5b: continuing a session somewhere else is the server's — the
/// packet built from what it can read, the new session started through the
/// one launch path, and the decision record carried into it.
void main() {
  final t0 = DateTime.utc(2026, 9, 27, 12);
  final local = Platform.isWindows ? 'windowsNative' : 'localPosix';

  late AppDatabase database;
  late SessionRegistry registry;
  late FakePtyLauncher pty;
  late Directory temp;
  late SessionContinuations continuations;
  late List<DecisionRecord> carried;
  var ids = 0;

  setUp(() {
    ids = 0;
    carried = [];
    temp = Directory.systemTemp.createTempSync('continuations_test');
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
      ['r1', 'p1', 'shop-api', 'local', temp.path, '$t0'],
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
    final transcript = File('${temp.path}${Platform.pathSeparator}t.jsonl')
      ..writeAsStringSync(
        '${jsonEncode({
          'type': 'user',
          'message': {'role': 'user', 'content': 'make the cart faster'},
        })}\n'
        '${jsonEncode({
          'type': 'assistant',
          'message': {
            'content': [
              {'type': 'text', 'text': 'I cached the totals.'},
            ],
          },
        })}\n',
      );
    pty = FakePtyLauncher();
    registry = SessionRegistry(launcher: pty);
    final rows = CheckoutRows(database);
    final launches = ServerSessionLauncher(
      launcher: HostedAgentLauncher(
        registry: registry,
        sessions: SessionDao(database),
        mcp: SessionMcpAccessPoint(mcp: null, configDirectory: temp.path),
        now: () => t0,
        newId: () => 'new-${++ids}',
        hostEnvironment: const {},
        environmentOf: rows.environment,
        handoffFiles: HandoffPacketFiles(
          Directory('${temp.path}${Platform.pathSeparator}handoff'),
        ),
      ),
      registry: registry,
      sessions: SessionDao(database),
      rows: rows,
      facts: DaemonCheckoutFacts(rows, windows: Platform.isWindows),
      installationsIn: DataService(database).installationsIn,
      pathProbe: const _Everywhere(),
      directoryPresent: (_) => true,
    );
    continuations = SessionContinuations(
      launches: launches,
      sessions: SessionDao(database),
      rows: rows,
      decisions: DecisionRecordDao(database),
      checkpoints: CheckpointDao(database),
      reach: CheckoutReach(database),
      transcripts: _Transcripts({
        '${AgentIds.claudeCode}/conv-1': transcript.path,
      }),
      carryDecision: carried.add,
    );
    SessionDao(database).insert(
      Session(
        id: 's1',
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'Cart speed',
        useWorktree: true,
        worktree: EnvironmentPath(environmentId: 'local', path: temp.path),
        status: SessionStatus.completed,
        createdAt: t0,
        externalSessionId: 'conv-1',
      ),
    );
    DecisionRecordDao(database).append(
      DecisionRecord(
        sessionId: 's1',
        kind: DecisionKind.approachRejected,
        summary: 'Memoising in the widget did not help',
        origin: DecisionOrigin.decisionTool,
        recordedAt: t0,
      ),
    );
    CheckpointDao(database).insert(
      Checkpoint(
        id: 'cp1',
        sessionId: 's1',
        repository: EnvironmentPath(environmentId: 'local', path: temp.path),
        sequence: 1,
        treeSha: 't',
        commitSha: 'c',
        parentCommitSha: 'p',
        headSha: 'h',
        reason: CheckpointReason.turnStart,
        createdAt: t0,
        turn: 1,
      ),
    );
  });

  tearDown(() async {
    for (final handle in pty.handles) {
      handle.finish(0);
    }
    await registry.shutdown();
    database.close();
    temp.deleteSync(recursive: true);
  });

  test(
    'the packet quotes the transcript, the decisions and the checkpoints',
    () async {
      final packet = await continuations.buildPacket(
        sessionId: 's1',
        targetAgentName: 'Codex',
        instruction: 'finish the cache',
        unresolvedTasks: ['invalidate on edit'],
      );
      final text = packet.render();
      expect(text, contains('make the cart faster'));
      expect(text, contains('I cached the totals.'));
      expect(text, contains('Memoising in the widget did not help'));
      expect(text, contains('cp1'));
      expect(text, contains('invalidate on edit'));
      expect(text, contains('finish the cache'));
      expect(packet.recapUnreadable, isFalse);
    },
  );

  test('handoff to an agent with no prompt file: the packet is the opening, '
      'in the same worktree, decisions carried', () async {
    final started = await continuations.handoff(
      sessionId: 's1',
      targetInstallationId: 'c1',
      instruction: 'finish the cache',
    );
    final child = SessionDao(database).getById(started.sessionId)!;
    expect(child.parentSessionId, 's1');
    expect(child.parentLink, SessionLink.handoff);
    expect(child.worktree?.path, temp.path);
    expect(pty.started.last.workingDirectory, temp.path);
    expect(pty.started.last.argv.last, contains('I cached the totals.'));
    expect(carried.single.sessionId, started.sessionId);
    expect(carried.single.recordedBySessionId, 's1');
  });

  test(
    'handoff to an agent that takes a file hands the packet over as one',
    () async {
      final started = await continuations.handoff(
        sessionId: 's1',
        targetInstallationId: 'a1',
        instruction: 'finish the cache',
      );
      expect(pty.started.last.argv, contains('--append-system-prompt-file'));
      expect(pty.started.last.argv.last, contains('finish the cache'));
      expect(
        File(
          '${temp.path}${Platform.pathSeparator}handoff'
          '${Platform.pathSeparator}handoff-${started.sessionId}.md',
        ).readAsStringSync(),
        contains('I cached the totals.'),
      );
    },
  );

  test('a handoff needs an instruction', () async {
    await expectLater(
      continuations.handoff(
        sessionId: 's1',
        targetInstallationId: 'c1',
        instruction: '  ',
      ),
      throwsA(isA<StateError>()),
    );
    expect(pty.started, isEmpty);
  });

  test('a fork of an agent with its own fork is native', () async {
    expect(continuations.forkPlanFor('s1').isNative, isTrue);
    final started = await continuations.fork(sessionId: 's1');
    final argv = pty.started.last.argv.join(' ');
    expect(argv, contains('--resume conv-1'));
    expect(argv, contains('--fork-session'));
    final child = SessionDao(database).getById(started.sessionId)!;
    expect(child.parentLink, SessionLink.fork);
    expect(child.title, 'Cart speed (fork)');
  });

  test('a fork with no known conversation falls back to a packet', () async {
    SessionDao(database).insert(
      Session(
        id: 's2',
        repositoryId: 'r1',
        agentInstallationId: 'c1',
        title: 'Codex work',
        useWorktree: false,
        status: SessionStatus.completed,
        createdAt: t0,
      ),
    );
    final plan = continuations.forkPlanFor('s2');
    expect(plan.isNative, isFalse);
    if (plan.isRefused) return;
    await continuations.fork(sessionId: 's2');
    expect(pty.started.last.argv.last, contains('Codex work'));
  });

  test(
    'forking from a checkpoint without checkpoints is refused in words',
    () async {
      await expectLater(
        continuations.forkFromCheckpoint(
          sessionId: 's1',
          turn: 1,
          preview: true,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('keeps no checkpoints'),
          ),
        ),
      );
    },
  );

  test(
    'a brief from a session nothing runs says so, and nothing is sent',
    () async {
      final brief = await continuations.sourceBrief('s1');
      expect(brief.text, isNull);
      expect(brief.notWritten, contains('nothing is running'));
    },
  );

  test('the targets list every agent installed where the session is', () {
    final targets = continuations.targetsFor('s1');
    expect(targets.map((t) => t.installation.id), ['a1', 'c1']);
    expect(targets.first.isSameAgent, isTrue);
    expect(targets.every((t) => t.canReceive), isTrue);
  });
}
