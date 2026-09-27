import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_companion_server/karmashala_companion_server.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/status/daemon_agent_status.dart';
import 'package:karmashala_host/src/status/daemon_prompt_answers.dart';
import 'package:karmashala_host/data.dart' show DataService;
import 'package:karmashala_host/src/mcp/tools/server_tool_context.dart';
import 'package:karmashala_host/src/mcp/tools/session_tool_set.dart';
import 'package:karmashala_remote/client.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_session/events.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_companion_server/store.dart';
import 'package:karmashala_store/devices.dart';
import 'package:test/test.dart';
import 'package:karmashala_session_engine/store.dart';

class _Clock implements Clock {
  _Clock(this.now);
  DateTime now;
  @override
  DateTime nowUtc() => now;
}

/// What the agent in a hosted session is doing, kept by the daemon from the
/// hooks it takes and the screen it holds — and its prompts answered there,
/// for the phone, the app and `session_answer` alike, with no app connected.
/// Nothing is stubbed but the PTY, which is fed a real agent's captured bytes.
void main() {
  final t0 = DateTime.utc(2026, 9, 25, 12);
  final deviceKey = Uint8List.fromList(List.generate(32, (i) => i + 7));

  late AppDatabase database;
  late SessionRegistry registry;
  late FakePtyLauncher launcher;
  late List<(String, Map<String, Object?>?)> published;
  late DaemonAgentStatus status;
  late DaemonPromptAnswers prompts;

  setUp(() {
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    database.execute(
      'INSERT INTO repositories (id, project_id, name, environment_id, path, '
      'created_at) VALUES (?, ?, ?, ?, ?, ?);',
      ['r1', 'p1', 'shop-api', 'local', '/src/shop/api', t0.toIso8601String()],
    );
    database.execute(
      'INSERT INTO agent_installations (id, agent_kind, environment_id, '
      'executable_path, created_at, executable_by_user) '
      'VALUES (?, ?, ?, ?, ?, ?);',
      ['a1', AgentIds.claudeCode, 'local', '/bin/claude', '$t0', 1],
    );
    SessionDao(database).insert(
      Session(
        id: 's1',
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'Fix the cart',
        useWorktree: false,
        status: SessionStatus.running,
        createdAt: t0,
      ),
    );
    launcher = FakePtyLauncher();
    registry = SessionRegistry(launcher: launcher);
    published = [];
    status = DaemonAgentStatus(
      registry: registry,
      database: database,
      publish: (id, body) => published.add((id, body)),
      interval: const Duration(hours: 1),
    );
    prompts = DaemonPromptAnswers(
      status: status,
      database: database,
      menuPoll: const Duration(milliseconds: 5),
      menuPatience: const Duration(milliseconds: 300),
    );
  });

  tearDown(() async {
    await status.close();
    for (final handle in launcher.handles) {
      handle.finish(0);
    }
    await registry.shutdown();
    database.close();
  });

  FakePtyHandle openAgent(String hostId) {
    registry.open(
      hostId,
      PtySpawnRequest(
        argv: const ['claude'],
        workingDirectory: '/src/shop/api',
        environment: const {},
        columns: 120,
        rows: 30,
      ),
    );
    return launcher.handles.last;
  }

  /// A real Claude Code's bytes, cut before the capture's own teardown.
  List<int> fixture(String name) {
    final text = File(
      '../app/test/features/agents/fixtures/$name.raw',
    ).readAsStringSync();
    final teardown = text.indexOf('Session terminated');
    return utf8.encode(teardown < 0 ? text : text.substring(0, teardown));
  }

  AgentHookEvent hook(
    String event, {
    String? pane,
    Map<String, Object?> more = const {},
  }) => AgentHookEvent(
    agent: AgentIds.claudeCode,
    event: event,
    sessionHeader: pane,
    receivedAt: DateTime.now().toUtc(),
    body: {'session_id': 'conv-1', 'hook_event_name': event, ...more},
  );

  HostedAgentStatus? last(String sessionId) {
    for (final (id, body) in published.reversed) {
      if (id == sessionId) return HostedAgentStatus.fromJson(body);
    }
    return null;
  }

  group('the status', () {
    test(
      'from the screen: a real permission modal is an open prompt',
      () async {
        openAgent(
          'karmashala_s1',
        ).emit(fixture('claude-code-permission-modal'));
        await pumpEventQueue();
        status.tick();

        final kept = last('s1')!;
        expect(kept.report.hasOpenPrompt, isTrue);
        expect(kept.report.source, AgentStatusSource.terminalGrid);
        expect(
          kept.report.evidence.join('\n'),
          contains('Do you want to create note.txt?'),
        );
        expect(status.snapshot().single['sessionId'], 's1');
      },
    );

    test('from hooks, by the pane they name and then by conversation', () {
      openAgent('karmashala_s1');
      status.tick();

      status.hook(hook('UserPromptSubmit', pane: 's1'));
      expect(last('s1')!.report.status, AgentActivityStatus.working);

      // A hook from a script too old to name its pane: its conversation does.
      status.hook(
        hook(
          'Notification',
          more: {
            'notification_type': 'permission_prompt',
            'message': 'Claude needs your permission to use Bash',
          },
        ),
      );
      expect(last('s1')!.report.hasOpenPrompt, isTrue);
    });

    test('a session no row names, or no agent runs, is not kept', () {
      openAgent('karmashala-check-1');
      openAgent('karmashala_nobody');
      status.tick();
      expect(status.snapshot(), isEmpty);
    });

    test('an ended session is let go, and watchers are told', () async {
      final handle = openAgent('karmashala_s1');
      status.tick();
      status.hook(hook('UserPromptSubmit', pane: 's1'));
      handle.finish(0);
      await registry.find('karmashala_s1')!.ended;
      status.tick();

      expect(published.last, ('s1', null));
      expect(status.statusOf('s1'), isNull);
    });

    test('a watcher gets the statuses in its snapshot, then each change', () {
      final feed = LifecycleFeed(registry, clock: () => t0)
        ..statusSnapshot = status.snapshot;
      final sent = <HostMessage>[];
      openAgent('karmashala_s1');
      status.tick();
      status.hook(hook('UserPromptSubmit', pane: 's1'));

      final watching = feed.watch(1, sent.add);
      addTearDown(watching.cancel);
      feed.publishAgentStatus('s1', last('s1')!.toJson());

      final snapshot = sent.first as WatchingMessage;
      expect(
        HostedAgentStatus.fromJson(snapshot.statuses.single)!.report.status,
        AgentActivityStatus.working,
      );
      final change = sent.whereType<AgentStatusMessage>().single;
      expect(change.sessionId, 's1');
      expect(HostedAgentStatus.fromJson(change.status)!.sessionId, 's1');
    });
  });

  group('with nobody watching', () {
    // Found live: an agent at its folder-trust question with the app open;
    // the app quits, the question is answered, the agent replies and stops;
    // the app, reopened, read `unknown` with no evidence, and kept reading it.
    test(
      'a status that moved while no watcher was connected is the one the '
      'next watcher\'s snapshot carries, however long ago it moved',
      () async {
        final clock = _Clock(t0);
        final kept = DaemonAgentStatus(
          registry: registry,
          database: database,
          publish: (_, _) {},
          clock: clock,
          interval: const Duration(hours: 1),
        );
        addTearDown(kept.close);
        final feed = LifecycleFeed(registry, clock: () => clock.now)
          ..statusSnapshot = kept.snapshot;
        final agent = openAgent('karmashala_s1')
          ..emit(fixture('claude-code-trust-prompt'));
        await pumpEventQueue();
        kept.tick();

        // The app is open and sees the folder-trust question, then quits.
        final first = <HostMessage>[];
        final app = feed.watch(1, first.add);
        final opened = HostedAgentStatus.fromJson(
          (first.first as WatchingMessage).statuses.single,
        )!;
        expect(opened.report.status, AgentActivityStatus.awaitingApproval);
        expect(opened.report.source, AgentStatusSource.terminalGrid);
        await app.cancel();
        expect(feed.hasWatchers, isFalse);

        // Answered here (the answer itself is tested below), the agent carries
        // on, replies and stops, on a screen the grid finds nothing on.
        agent.emit(utf8.encode('\x1b[2J\x1b[H\u25cf PONG\r\n'));
        await pumpEventQueue();
        for (final event in ['SessionStart', 'UserPromptSubmit', 'Stop']) {
          clock.now = clock.now.add(const Duration(seconds: 2));
          final fired = AgentHookEvent(
            agent: AgentIds.claudeCode,
            event: event,
            sessionHeader: 's1',
            receivedAt: clock.now,
            body: {'session_id': 'conv-1', 'hook_event_name': event},
          );
          kept.hook(fired);
          feed.relayHook(fired);
          kept.tick();
        }

        // The app comes back well after the hook's freshness.
        clock.now = clock.now.add(const Duration(minutes: 20));
        kept.tick();
        final second = <HostMessage>[];
        final back = feed.watch(2, second.add);
        addTearDown(back.cancel);
        final latest = HostedAgentStatus.fromJson(
          (second.first as WatchingMessage).statuses.single,
        )!;
        expect(latest.sessionId, 's1');
        expect(latest.report.status, AgentActivityStatus.idle);
        expect(latest.report.source, AgentStatusSource.hook);
        expect(latest.report.detail, 'Stop');
      },
    );
  });

  group('answers', () {
    late FakePtyHandle agent;

    setUp(() async {
      agent = openAgent('karmashala_s1')
        ..emit(fixture('claude-code-permission-modal'));
      await pumpEventQueue();
      status.tick();
    });

    String typed() => [for (final w in agent.writes) utf8.decode(w)].join();

    test(
      'a client\'s approve is the highlighted "Yes", filed as decided',
      () async {
        final answered = await prompts.answerFrame(
          4,
          const ApprovalAnswerRequest(sessionId: 's1', approve: true).toJson(),
        );

        expect(answered.ok, isTrue, reason: answered.message);
        expect(answered.answered, 'Yes');
        expect(typed(), '\r');
        final filed = DecisionRecordDao(database).forSession('s1').single;
        expect(filed.kind, DecisionKind.approvalGranted);
        expect(filed.origin, DecisionOrigin.approvalPrompt);
      },
    );

    test('written although a pane holds the write token', () async {
      registry
          .find('karmashala_s1')!
          .token
          .claim('the-desktop-pane', DateTime.now());
      final answered = await prompts.answerFrame(
        5,
        const ApprovalAnswerRequest(sessionId: 's1', approve: false).toJson(),
      );
      expect(answered.ok, isTrue, reason: answered.message);
      expect(typed(), '\x1b', reason: 'the declared Esc declines the tool');
    });

    test('a session with no prompt open is refused, nothing typed', () async {
      status.hook(hook('Stop', pane: 's1'));
      final answered = await prompts.answerFrame(
        6,
        const ApprovalAnswerRequest(sessionId: 's1', approve: true).toJson(),
      );
      expect(answered.ok, isFalse);
      expect(answered.refusal, PromptRefusalKind.refused);
      expect(typed(), isEmpty);
    });

    test(
      'session_answer is answered here for a session the host holds',
      () async {
        final tools = SessionToolSet(
          ServerToolContext(
            database: database,
            data: DataService(database),
            dataDirectory: '/nowhere',
          ),
          prompts: prompts,
          registry: registry,
          appConnected: () => true,
        );
        final result =
            await tools.call('session_answer', {
                  'sessionId': 's1',
                  'decision': 'approve',
                }, 'caller-1')!
                as Map<String, Object?>;

        expect(result['answered'], 'Yes');
        expect(typed(), '\r');
        expect(
          DecisionRecordDao(database).forSession('s1').single.decidedBy,
          'an agent in session caller-1',
        );
        expect(
          tools.call('session_answer', {
            'sessionId': 'elsewhere',
            'decision': 'approve',
          }, null),
          isNull,
          reason: 'a session this host does not hold is the app\'s',
        );
        expect(tools.call('open_session', {}, null), isNull);
      },
    );
  });

  group('a phone, with the app closed', () {
    late DaemonCompanion companion;
    late StreamController<LifecycleEvent> events;
    late FakePtyHandle agent;

    setUp(() async {
      PairedDeviceDao(database).insert(
        PairedDevice(
          id: 'pixel',
          name: 'Pixel',
          deviceKey: deviceKey,
          capabilities: CapabilitySet.all,
          generation: 0,
          createdAt: t0,
        ),
      );
      events = StreamController<LifecycleEvent>.broadcast();
      companion = DaemonCompanion(
        database: database,
        registry: registry,
        hostName: 'desk',
        lanPort: 0,
        config: const CompanionConfig(enabled: true),
        transcriptPollInterval: Duration.zero,
        screens: RegistryScreens(registry, enterDelay: Duration.zero),
        prompts: prompts,
        clock: () => t0,
      );
      await companion.start(sessionEvents: events.stream);
      agent = openAgent('karmashala_s1')
        ..emit(fixture('claude-code-permission-modal'));
      await pumpEventQueue();
      status.tick();
    });

    tearDown(() async {
      await companion.close();
      await events.close();
    });

    Future<CompanionClient> dial() async {
      final port = companion.port!;
      final client = CompanionClient(
        pairing: CompanionPairing(
          hostId: hostDeviceIdFor(database),
          deviceId: DeviceId.parse('c' * 32),
          deviceKey: deviceKey,
          capabilities: CapabilitySet.all,
          relay: Uri.parse('https://unused.invalid'),
          generation: 0,
          hostName: 'desk',
          directEndpoint: '127.0.0.1:$port',
        ),
        store: InMemoryCompanionStore(),
      );
      addTearDown(client.close);
      await client.connect(
        transport: LanTransport(host: '127.0.0.1', port: port)..start(),
        generation: 0,
        helloTimeout: const Duration(seconds: 10),
      );
      return client;
    }

    test('sees the session waiting for approval', () async {
      final client = await dial();
      final row = (await client.listSessions()).singleWhere(
        (s) => s.sessionId == 's1',
      );
      expect(row.attention, kAttentionNeedsApproval);
    });

    test('reads the prompt as a menu, and answers it by option', () async {
      final client = await dial();
      final asked = client.events
          .where((e) => e is ApprovalRequestedEvent)
          .cast<ApprovalRequestedEvent>()
          .first;
      await client.subscribeSession('s1');
      final evidence = (await asked.timeout(
        const Duration(seconds: 10),
      )).request;

      expect(evidence.waiting, RemoteWaitKind.approval);
      expect(evidence.menu, isNotNull);
      expect(evidence.menu!.options.first, 'Yes');
      expect(
        evidence.approveLabel,
        isNull,
        reason: 'never Enter beside a menu',
      );

      final chosen = await client.answerMenu(
        RemoteMenuAnswerRequest(
          sessionId: 's1',
          menuId: evidence.menu!.menuId,
          option: 0,
        ),
      );
      expect(chosen, 'Yes');
      expect(utf8.decode(agent.writes.single), '\r');
    });

    test('approves', () async {
      final client = await dial();
      expect(await client.answerApproval('s1', approve: true), 'Yes');
      expect(utf8.decode(agent.writes.single), '\r');
    });

    /// The turn ends: Claude Code's idle screen (the real capture, after its
    /// reply) and its `Stop`.
    Future<void> turnEnds() async {
      final idle = File(
        '../app/test/features/agents/fixtures/claude-code-tui.raw',
      ).readAsStringSync();
      agent.emit(
        utf8.encode(
          '\x1b[2J\x1b[H${idle.substring(0, (idle.length * 0.85).round())}',
        ),
      );
      await pumpEventQueue();
      status.hook(hook('Stop', pane: 's1'));
      status.tick();
    }

    // Found on a real phone (2.1.283, app closed): the header said "Working"
    // and "your desktop keeps no record of what this session is running"
    // under an agent at rest; a minute later its idle nudge put it in the
    // inbox as "needs you".
    test('an agent at rest reads idle, running nothing, waiting on '
        'nobody — its idle nudge included', () async {
      await turnEnds();
      status.hook(
        hook(
          'Notification',
          pane: 's1',
          more: {
            'notification_type': 'idle_prompt',
            'message': 'Claude is waiting for your input',
          },
        ),
      );
      status.tick();

      final client = await dial();
      final row = (await client.listSessions()).singleWhere(
        (s) => s.sessionId == 's1',
      );
      expect(row.status, 'running');
      expect(row.activity, 'idle');
      expect(row.attention, isNull);
      expect((await client.activity('s1')).absence, isNull);
    });

    test(
      'mid-turn it reads working, on something the host cannot name',
      () async {
        status.hook(hook('UserPromptSubmit', pane: 's1'));
        final client = await dial();
        final row = (await client.listSessions()).singleWhere(
          (s) => s.sessionId == 's1',
        );
        expect(row.activity, 'working');
        expect(
          (await client.activity('s1')).absence,
          RemoteActivityAbsence.noRecord,
        );
      },
    );

    // Found on the same phone: after its turn Claude Code drew "Teach auto
    // mode about your environment?" under the idle footer, and the phone was
    // never asked.
    test('a menu drawn under the idle footer after the turn is asked, and '
        'answered by option', () async {
      await turnEnds();
      expect(last('s1')!.report.status, AgentActivityStatus.idle);
      agent.emit(fixture('claude-code-auto-mode-offer'));
      await pumpEventQueue();
      status.tick();
      expect(last('s1')!.report.hasOpenPrompt, isTrue);

      final client = await dial();
      final row = (await client.listSessions()).singleWhere(
        (s) => s.sessionId == 's1',
      );
      expect(row.attention, kAttentionNeedsApproval);
      expect(row.activity, 'awaitingApproval');

      final asked = client.events
          .where((e) => e is ApprovalRequestedEvent)
          .cast<ApprovalRequestedEvent>()
          .first;
      await client.subscribeSession('s1');
      final evidence = (await asked.timeout(
        const Duration(seconds: 10),
      )).request;
      expect(evidence.menu!.options, ['Yes', 'Not now', "Don't show again"]);
      expect(
        evidence.menu!.prompt,
        contains('Teach auto mode about your environment?'),
      );

      final chosen = await client.answerMenu(
        RemoteMenuAnswerRequest(
          sessionId: 's1',
          menuId: evidence.menu!.menuId,
          option: 0,
        ),
      );
      expect(chosen, 'Yes');
      expect(utf8.decode(agent.writes.single), '\r');
    });
  });
}
