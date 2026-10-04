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
import 'package:karmashala_host/src/sessions/launch/session_handoffs.dart';
import 'package:karmashala_host/src/sessions/launch/server_session_launcher.dart';
import 'package:karmashala_host/src/sessions/launch/session_continuations.dart';
import 'package:karmashala_host/src/sessions/session_queue.dart';
import 'package:karmashala_host/src/status/daemon_agent_status.dart';
import 'package:karmashala_host/src/status/turn_settlement.dart';
import 'package:karmashala_session/launch.dart' show SessionForkPlan;
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
    TranscriptMessage(
      role: role,
      text: text,
      agentInstallationId: installation,
    );

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
  bool Function(String sessionId)? turnRunning;
  var ids = 0;

  SessionDao rows() => SessionDao(database);

  setUp(() async {
    ids = 0;
    running = false;
    turnRunning = null;
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
      'VALUES (?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?), '
      '(?, ?, ?, ?, ?, ?);',
      [
        'a1', AgentIds.claudeCode, 'local', '/bin/claude', '$t0', 1, //
        'c1', AgentIds.codex, 'local', '/bin/codex', '$t0', 1, //
        'acp1', AgentIds.claudeAcp, 'local', 'claude-agent-acp', '$t0', 1, //
        'a2', AgentIds.claudeCode, 'local', '/opt/claude', '$t0', 1,
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
        handoffs: SessionHandoffs(
          dao: SessionHandoffDao(database),
          root: Directory('${temp.path}${Platform.pathSeparator}handoff'),
          now: () => t0,
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
      conversationOf: conversation == null ? null : (_) async => conversation!,
      turnRunning: (id) => turnRunning?.call(id) ?? running,
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
  SessionContinuations reading(
    List<TranscriptMessage> messages, {
    bool Function(String sessionId, String reason)? cancelResume,
    void Function(String sessionId)? holdQueue,
    void Function(String sessionId)? releaseQueue,
  }) {
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
      turnRunning: (id) => turnRunning?.call(id) ?? running,
      nextMessageOrdinal: SessionMessageDao(database).countForSession,
      onSwitched: (id, _) => switched.add(id),
      cancelResume: cancelResume,
      holdQueue: holdQueue,
      releaseQueue: releaseQueue,
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
    await continuations.switchAgent(
      sessionId: 's1',
      targetInstallationId: 'c1',
    );
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
    // The recap travels as the system prompt — inline, as this command line
    // carries it — and the instruction as the turn: no file for the agent to
    // ask about.
    expect(argv, contains('--append-system-prompt'));
    expect(argv.last, 'review them');
    final packet = argv[argv.indexOf('--append-system-prompt') + 1];
    expect(packet, contains('Tests added for the cache.'));
    expect(packet, isNot(contains('I cached the totals.')));
    expect(packet, contains('review them'));
    expect(
      spans
          .forSession('s1')
          .map((s) => (s.seq, s.agentInstallationId, s.externalSessionId)),
      [(0, 'a1', 'conv-1'), (1, 'c1', 'conv-c'), (2, 'a1', 'conv-1')],
    );
    expect(rows().getById('s1')!.externalSessionId, 'conv-1');
  });

  test('an agent that names its conversation after it starts keeps it '
      'in its span, and a switch back to it resumes it', () async {
    await launches.resume('s1');
    await continuations.switchAgent(
      sessionId: 's1',
      targetInstallationId: 'c1',
    );
    // Codex announces its own id only once it runs.
    rows().updateExternalSessionId('s1', 'codex-conv');
    expect(spans.forSession('s1').last.externalSessionId, 'codex-conv');

    await reading(
      const [],
    ).switchAgent(sessionId: 's1', targetInstallationId: 'a1');
    expect(spans.forSession('s1').map((s) => s.externalSessionId), [
      'conv-1',
      'codex-conv',
      'conv-1',
    ]);

    await reading(
      const [],
    ).switchAgent(sessionId: 's1', targetInstallationId: 'c1');
    expect(pty.started.last.argv.first, '/bin/codex');
    expect(pty.started.last.argv, contains('codex-conv'));
    expect(rows().getById('s1')!.externalSessionId, 'codex-conv');
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

  test('a terminal agent whose reader lost a finished turn is switched once '
      'its screen has been quiet, and refused while it still moves', () async {
    const quiet = Duration(milliseconds: 300);
    final status = DaemonAgentStatus(
      registry: registry,
      database: database,
      publish: (_, _) {},
      interval: const Duration(hours: 1),
    );
    final turns = TurnSettlement(
      status: status,
      quietPeriod: quiet,
      poll: const Duration(milliseconds: 10),
    )..start();
    final queue = SessionQueue(
      dao: SessionQueueDao(database),
      status: status,
      turns: turns,
    )..start();
    addTearDown(() async {
      await queue.close();
      await turns.close();
      await status.close();
    });
    turnRunning = queue.busy;
    void says(AgentActivityStatus kind) => status.report(
      's1',
      AgentStatusReport(
        agentId: AgentIds.claudeCode,
        sessionId: 's1',
        status: kind,
        observedAt: DateTime.now().toUtc(),
        source: AgentStatusSource.terminalGrid,
      ),
    );

    await launches.resume('s1');
    final agent = pty.handles.last..emit(utf8.encode('> \r\n'));
    await pumpEventQueue();
    says(AgentActivityStatus.working);
    says(AgentActivityStatus.unknown);
    agent.emit(utf8.encode('still writing\r\n'));
    await expectLater(
      continuations.switchAgent(sessionId: 's1', targetInstallationId: 'c1'),
      throwsA(isA<StateError>()),
    );

    await Future<void>.delayed(quiet * 2);
    final started = await continuations.switchAgent(
      sessionId: 's1',
      targetInstallationId: 'c1',
    );
    expect(started.session.agentInstallationId, 'c1');
  });

  test('a switch to the agent already running it is refused', () async {
    await expectLater(
      continuations.switchAgent(sessionId: 's1', targetInstallationId: 'a1'),
      throwsA(isA<StateError>()),
    );
    expect(spans.forSession('s1'), isEmpty);
  });

  test('another installation of the same agent is a switch: it starts a '
      'conversation of its own, never the id the first one holds', () async {
    // Claude Code's conversation is named after the row it started in.
    rows().updateExternalSessionId('s1', 's1');
    await launches.resume('s1');

    final started = await reading(
      const [],
    ).switchAgent(sessionId: 's1', targetInstallationId: 'a2');

    expect(started.session.agentInstallationId, 'a2');
    final argv = pty.started.last.argv;
    expect(argv.first, '/opt/claude');
    expect(argv, isNot(contains('--resume')));
    final minted = argv[argv.indexOf('--session-id') + 1];
    expect(minted, isNot('s1'));
    expect(rows().getById('s1')!.externalSessionId, minted);
    expect(
      spans
          .forSession('s1')
          .map((s) => (s.agentInstallationId, s.externalSessionId)),
      [('a1', 's1'), ('a2', minted)],
    );

    // Back to the first installation: its own conversation, resumed.
    await reading(
      const [],
    ).switchAgent(sessionId: 's1', targetInstallationId: 'a1');
    final back = pty.started.last.argv;
    expect(back.first, '/bin/claude');
    expect(back.join(' '), contains('--resume s1'));
    expect(rows().getById('s1')!.externalSessionId, 's1');
  });

  test('a new agent that will not start takes the switch back, tries the '
      'old one again, and says plainly when that failed too', () async {
    pty.failWith = const PtyException('no such program');
    await expectLater(
      continuations.switchAgent(sessionId: 's1', targetInstallationId: 'c1'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(contains('did not start'), contains('resume it')),
        ),
      ),
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
    expect(pty.started.last.argv, contains('--append-system-prompt'));
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

  test('a session that never switched is offered every other installation, '
      'another of the same agent included, the running one refused', () {
    final targets = continuations.targetsFor('s1', inPlace: true);
    expect(
      targets.map((t) => (t.installation.id, t.canReceive)),
      unorderedEquals([
        ('a1', false),
        ('a2', true),
        ('c1', true),
        ('acp1', true),
      ]),
    );
    expect(targets.any((t) => t.resumesConversation), isFalse);
  });

  test(
    'a switch cancels the leaving agent\'s armed resume and says so',
    () async {
      await launches.resume('s1');
      final cancelled = <(String, String)>[];
      final started = await reading(
        const [],
        cancelResume: (id, reason) {
          cancelled.add((id, reason));
          return true;
        },
      ).switchAgent(sessionId: 's1', targetInstallationId: 'c1');

      expect(cancelled.single.$1, 's1');
      expect(cancelled.single.$2, contains('Claude Code'));
      expect(started.switchNotice, contains('cancelled'));
      expect(started.switchNotice, contains('Codex'));
    },
  );

  test(
    'the session\'s queue is held for the whole switch and let go after',
    () async {
      await launches.resume('s1');
      final events = <String>[];
      await reading(
        const [],
        holdQueue: (id) => events.add('hold $id'),
        releaseQueue: (id) => events.add('release $id'),
      ).switchAgent(sessionId: 's1', targetInstallationId: 'c1');
      expect(events, ['hold s1', 'release s1']);

      // A switch that fails lets go too.
      pty.failWith = const PtyException('no such program');
      events.clear();
      await expectLater(
        reading(
          const [],
          holdQueue: (id) => events.add('hold $id'),
          releaseQueue: (id) => events.add('release $id'),
        ).switchAgent(sessionId: 's1', targetInstallationId: 'a1'),
        throwsA(anything),
      );
      expect(events, ['hold s1', 'release s1']);
    },
  );

  test('a handoff or fork of a switched session carries every agent\'s '
      'turns, and the CLI\'s own fork is not offered', () async {
    await launches.resume('s1');
    await continuations.switchAgent(
      sessionId: 's1',
      targetInstallationId: 'c1',
    );
    rows().updateExternalSessionId('s1', 'conv-c');
    // Back on Claude Code, which forks natively on its own.
    await reading(
      const [],
    ).switchAgent(sessionId: 's1', targetInstallationId: 'a1');
    final over = reading([
      _said('user', 'make the cart faster', 'a1'),
      _said('agent', 'I cached the totals.', 'a1'),
      _said(kAgentSwitchRole, 'packet', 'c1'),
      _said('agent', 'Tests added for the cache.', 'c1'),
    ]);
    final packet = (await over.buildPacket(
      sessionId: 's1',
      targetAgentName: 'Claude Code',
      instruction: 'carry on',
    )).render();
    expect(packet, contains('I cached the totals.'));
    expect(packet, contains('Tests added for the cache.'));
    expect(over.forkPlanFor('s1').isNative, isFalse);
    // Claude Code would fork natively had it run the session alone.
    expect(
      SessionForkPlan.decide(
        descriptor: AgentRegistry.builtIn.byId(AgentIds.claudeCode),
        agentName: 'Claude Code',
        externalSessionId: 'conv-1',
      ).isNative,
      isTrue,
    );
  });
}
