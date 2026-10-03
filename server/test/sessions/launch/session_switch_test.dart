import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart' show PathProbe;
import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart'
    show CliStoreLocator, TranscriptMessage, kAgentSwitchRole;
import 'package:karmashala_acp/karmashala_acp.dart' show TextContent;
import 'package:karmashala_acp/testing.dart';
import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_checkpoints/store.dart' show CheckpointDao;
import 'package:karmashala_host/data.dart' show DataService;
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/acp/acp_runtimes.dart';
import 'package:karmashala_host/src/automations/daemon_checkout_facts.dart';
import 'package:karmashala_host/src/automations/hosted_agent_launcher.dart';
import 'package:karmashala_host/src/data/conversations_handler.dart'
    show TranscriptStores;
import 'package:karmashala_host/src/mcp/tools/checkout_reach.dart';
import 'package:karmashala_host/src/sessions/launch/handoff_packet_files.dart';
import 'package:karmashala_host/src/sessions/launch/server_session_launcher.dart';
import 'package:karmashala_host/src/sessions/launch/session_continuations.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import '../../acp/acp_fixture.dart';

final class _Everywhere implements PathProbe {
  const _Everywhere();
  @override
  bool? fileExists(String path) => true;
  @override
  bool isLink(String path) => false;
  @override
  String? linkTarget(String path) => null;
}

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

TranscriptMessage _said(String role, String text, String installation) =>
    TranscriptMessage(role: role, text: text, agentInstallationId: installation);

/// One thread, many agents: a switch keeps the row, stops the running agent
/// as `switched`, writes the spans, and starts the new agent with what it
/// missed — its own conversation resumed when it ran the session before.
void main() {
  final t0 = DateTime.utc(2026, 10, 3, 12);
  final local = Platform.isWindows ? 'windowsNative' : 'localPosix';

  late AppDatabase database;
  late SessionRegistry registry;
  late FakePtyLauncher pty;
  late Directory temp;
  late SessionContinuations continuations;
  late ServerSessionLauncher launches;
  late SessionAgentSpanDao spans;
  late List<String?> closeReasons;
  late List<AcpSessionStart> acpStarts;
  late FakeAcpAgent acpAgent;
  late List<String> switched;
  late Timer reaper;
  List<TranscriptMessage>? conversation;
  var running = false;
  var ids = 0;

  SessionDao rows() => SessionDao(database);

  setUp(() async {
    ids = 0;
    running = false;
    conversation = null;
    switched = [];
    closeReasons = [];
    acpStarts = [];
    acpAgent = FakeAcpAgent(sessionIdPrefix: 'acp-conv');
    temp = Directory.systemTemp.createTempSync('switch_test');
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
      'VALUES (?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?);',
      [
        'a1', AgentIds.claudeCode, 'local', '/bin/claude', '$t0', 1, //
        'c1', AgentIds.codex, 'local', '/bin/codex', '$t0', 1, //
        'acp1', AgentIds.claudeAcp, 'local', 'claude-agent-acp', '$t0', 1,
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
    // A terminal told to stop, stops.
    reaper = Timer.periodic(const Duration(milliseconds: 5), (_) {
      for (final handle in pty.handles) {
        if (handle.signals.isNotEmpty) handle.finish(143);
      }
    });
    registry.changes.listen((change) {
      if (change is SessionClosed) closeReasons.add(change.reason);
    });
    final checkoutRows = CheckoutRows(database);
    launches = ServerSessionLauncher(
      launcher: HostedAgentLauncher(
        registry: registry,
        sessions: SessionDao(database),
        mcp: SessionMcpAccessPoint(mcp: null, configDirectory: temp.path),
        now: () => t0,
        newId: () => 'new-${++ids}',
        hostEnvironment: const {},
        environmentOf: checkoutRows.environment,
        handoffFiles: HandoffPacketFiles(
          Directory('${temp.path}${Platform.pathSeparator}handoff'),
        ),
        acpRuntimes: (start) {
          acpStarts.add(start);
          acpAgent = FakeAcpAgent(sessionIdPrefix: 'acp-conv');
          return runtimeOver(
            FakeAcpProcess(acpAgent),
            database: database,
            workingDirectory: start.directory.path,
            sessionId: start.sessionId,
            agentId: start.agentId,
            spec: start.spec,
            resumeSessionId: start.resumeSessionId,
          );
        },
        windows: false,
      ),
      registry: registry,
      sessions: SessionDao(database),
      rows: checkoutRows,
      facts: DaemonCheckoutFacts(checkoutRows, windows: Platform.isWindows),
      installationsIn: DataService(database).installationsIn,
      pathProbe: const _Everywhere(),
      directoryPresent: (_) => true,
    );
    spans = SessionAgentSpanDao(database);
    continuations = SessionContinuations(
      launches: launches,
      sessions: SessionDao(database),
      rows: checkoutRows,
      decisions: DecisionRecordDao(database),
      checkpoints: CheckpointDao(database),
      reach: CheckoutReach(database),
      transcripts: _Transcripts({
        '${AgentIds.claudeCode}/conv-1': transcript.path,
      }),
      carryDecision: (_) {},
      spans: spans,
      conversationOf: conversation == null
          ? null
          : (_) async => conversation!,
      turnRunning: (_) => running,
      nextMessageOrdinal: SessionMessageDao(database).countForSession,
      onSwitched: (id, _) => switched.add(id),
      now: () => t0.add(Duration(minutes: switched.length + 1)),
    );
    rows().insert(
      Session(
        id: 's1',
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'Cart speed',
        useWorktree: false,
        status: SessionStatus.completed,
        createdAt: t0,
        externalSessionId: 'conv-1',
      ),
    );
  });

  tearDown(() async {
    reaper.cancel();
    for (final handle in pty.handles) {
      handle.finish(0);
    }
    await registry.shutdown();
    database.close();
    temp.deleteSync(recursive: true);
  });

  /// [continuations] reading [messages] as the session's stitched transcript.
  SessionContinuations reading(List<TranscriptMessage> messages) {
    conversation = messages;
    return SessionContinuations(
      launches: launches,
      sessions: SessionDao(database),
      rows: CheckoutRows(database),
      decisions: DecisionRecordDao(database),
      checkpoints: CheckpointDao(database),
      reach: CheckoutReach(database),
      transcripts: _Transcripts(const {}),
      carryDecision: (_) {},
      spans: spans,
      conversationOf: (_) async => conversation!,
      turnRunning: (_) => running,
      nextMessageOrdinal: SessionMessageDao(database).countForSession,
      onSwitched: (id, _) => switched.add(id),
      now: () => t0.add(Duration(minutes: switched.length + 1)),
    );
  }

  test('the first switch writes span 0 and 1, ends the old agent as '
      'switched and starts the new one in the same row', () async {
    await launches.resume('s1');
    expect(pty.started.single.argv.join(' '), contains('--resume conv-1'));

    final started = await continuations.switchAgent(
      sessionId: 's1',
      targetInstallationId: 'c1',
    );

    expect(started.session.id, 's1');
    expect(closeReasons, [SessionEndedWithoutCode.switched]);
    expect(
      spans
          .forSession('s1')
          .map((s) => (s.seq, s.agentInstallationId, s.externalSessionId)),
      [(0, 'a1', 'conv-1'), (1, 'c1', null)],
    );
    expect(spans.forSession('s1').last.carriedPacket, contains('Codex'));
    final row = rows().getById('s1')!;
    expect(row.agentInstallationId, 'c1');
    expect(row.status, SessionStatus.running);
    expect(row.title, 'Cart speed');
    // A new Codex conversation, told everything: the packet on its argv.
    expect(pty.started.last.argv.first, '/bin/codex');
    expect(pty.started.last.argv.last, contains('I cached the totals.'));
    expect(pty.started.last.argv.last, contains(kSwitchInstruction));
    expect(switched, ['s1']);
  });

  test('switching back resumes the earlier conversation and recaps only '
      'the turns it missed', () async {
    await launches.resume('s1');
    await continuations.switchAgent(sessionId: 's1', targetInstallationId: 'c1');
    rows().updateExternalSessionId('s1', 'conv-c');

    await reading([
      _said('user', 'make the cart faster', 'a1'),
      _said('agent', 'I cached the totals.', 'a1'),
      _said(kAgentSwitchRole, 'packet', 'c1'),
      _said('user', 'now add tests', 'c1'),
      _said('agent', 'Tests added for the cache.', 'c1'),
    ]).switchAgent(
      sessionId: 's1',
      targetInstallationId: 'a1',
      instruction: 'review them',
    );

    final argv = pty.started.last.argv;
    expect(argv.first, '/bin/claude');
    expect(argv.join(' '), contains('--resume conv-1'));
    expect(argv, isNot(contains('--append-system-prompt-file')));
    expect(argv.last, contains('Tests added for the cache.'));
    expect(argv.last, isNot(contains('I cached the totals.')));
    expect(argv.last, contains('review them'));
    expect(
      spans
          .forSession('s1')
          .map((s) => (s.seq, s.agentInstallationId, s.externalSessionId)),
      [(0, 'a1', 'conv-1'), (1, 'c1', 'conv-c'), (2, 'a1', 'conv-1')],
    );
    expect(rows().getById('s1')!.externalSessionId, 'conv-1');
  });

  test('a switch is refused while a turn runs, and nothing moves', () async {
    await launches.resume('s1');
    running = true;
    await expectLater(
      continuations.switchAgent(sessionId: 's1', targetInstallationId: 'c1'),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', contains('turn')),
      ),
    );
    expect(spans.forSession('s1'), isEmpty);
    expect(rows().getById('s1')!.agentInstallationId, 'a1');
    expect(closeReasons, isEmpty);
    expect(pty.started, hasLength(1));
  });

  test('a switch to the agent already running it is refused', () async {
    await expectLater(
      continuations.switchAgent(sessionId: 's1', targetInstallationId: 'a1'),
      throwsA(isA<StateError>()),
    );
    expect(spans.forSession('s1'), isEmpty);
  });

  test('a new agent that will not start takes the switch back', () async {
    pty.failWith = const PtyException('no such program');
    await expectLater(
      continuations.switchAgent(sessionId: 's1', targetInstallationId: 'c1'),
      throwsA(anything),
    );
    expect(spans.forSession('s1'), isEmpty);
    final row = rows().getById('s1')!;
    expect(row.agentInstallationId, 'a1');
    expect(row.externalSessionId, 'conv-1');
  });

  test('ACP to a terminal agent and back, the server keeping the ACP turns '
      'by ordinal', () async {
    rows().insert(
      Session(
        id: 's3',
        repositoryId: 'r1',
        agentInstallationId: 'acp1',
        title: 'Over ACP',
        useWorktree: false,
        status: SessionStatus.completed,
        createdAt: t0,
        externalSessionId: 'acp-conv-9',
      ),
    );
    await launches.resume('s3');
    expect(registry.findAcp('karmashala_s3')!.lifecycle.hasEnded, isFalse);

    await reading(const [
      TranscriptMessage(role: 'user', text: 'tidy the routes'),
      TranscriptMessage(role: 'agent', text: 'Routes tidied.'),
    ]).switchAgent(sessionId: 's3', targetInstallationId: 'a1');

    expect(closeReasons, [SessionEndedWithoutCode.switched]);
    expect(registry.findAcp('karmashala_s3'), isNull);
    expect(pty.started.last.argv.first, '/bin/claude');
    expect(pty.started.last.argv, contains('--append-system-prompt-file'));
    final afterFirst = spans.forSession('s3');
    expect(afterFirst.first.firstMessageOrdinal, 0);
    expect(afterFirst.last.firstMessageOrdinal, isNull);
    // Claude takes the row's own id for its new conversation.
    expect(rows().getById('s3')!.externalSessionId, 's3');

    await reading([
      _said('user', 'tidy the routes', 'acp1'),
      _said('agent', 'Routes tidied.', 'acp1'),
      _said(kAgentSwitchRole, 'packet', 'a1'),
      _said('agent', 'Docs written for the routes.', 'a1'),
    ]).switchAgent(sessionId: 's3', targetInstallationId: 'acp1');

    expect(acpStarts.last.resumeSessionId, 'acp-conv-9');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final told = [
      for (final block in acpAgent.prompts.last)
        if (block is TextContent) block.text,
    ].join();
    expect(told, contains('Docs written for the routes.'));
    expect(told, isNot(contains('Routes tidied.')));
    final all = spans.forSession('s3');
    expect(all.map((s) => (s.agentInstallationId, s.externalSessionId)), [
      ('acp1', 'acp-conv-9'),
      ('a1', 's3'),
      ('acp1', 'acp-conv-9'),
    ]);
    expect(all.last.firstMessageOrdinal, isNotNull);
    expect(rows().getById('s3')!.agentInstallationId, 'acp1');
  });

  test('a session that never switched is offered every other agent, the '
      'running one refused', () {
    final targets = continuations.targetsFor('s1', inPlace: true);
    expect(
      targets.map((t) => (t.installation.id, t.canReceive)),
      unorderedEquals([('a1', false), ('c1', true), ('acp1', true)]),
    );
    expect(targets.any((t) => t.resumesConversation), isFalse);
  });
}
