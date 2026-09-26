import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'dart:async';
import 'dart:convert';

import 'package:agent_cli/descriptors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_hook_intake.dart';
import 'package:karmashala/src/features/agents/application/agent_status_providers.dart';
import 'package:karmashala/src/features/checkpoints/application/session_checkpoint_recorder.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_agent_statuses.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_providers.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_subscriber.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/relayed_agent_hook.dart';
import 'package:karmashala/src/features/sessions/application/session_liveness_reconciler.dart';
import 'package:karmashala/src/features/sessions/application/session_prompt_answers.dart';
import 'package:karmashala/src/features/sessions/application/session_signals.dart';
import 'package:karmashala/src/features/sessions/application/session_wait.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_store/database.dart';

import '../../support/fake_data_server.dart';
import '../../support/workspace_mirror.dart';
import '../../support/fake_host_lifecycle.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';

DateTime _at(int second) => testTime.add(Duration(seconds: second));

/// The checkpoint recorder as a hook's hold sees it: [settled] waits on
/// [capture] while one is set, and the unheld / expired marks are recorded.
class _RecordingRecorder extends SessionCheckpointRecorder {
  Completer<void>? capture;
  var settledCalls = 0;
  final unheld = <String>[];
  final expired = <String>[];

  @override
  Future<void> settled(String sessionId) async {
    settledCalls++;
    await capture?.future;
  }

  @override
  void noteToolUnheld(String sessionId) => unheld.add(sessionId);

  @override
  void noteHoldExpired(String sessionId) => expired.add(sessionId);
}

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late AppDatabase db;
  late FakeDataServer server;
  late DataClient data;
  late FakeSessionRows dao;
  late FakeHostLifecycle host;
  late ProviderContainer container;
  late _RecordingRecorder recorder;

  setUp(() async {
    db = AppDatabase.memory();
    server = FakeDataServer()..mirrorInto(db);
    data = await server.connect();
    server.environmentRows
      ..upsert(windowsEnv())
      ..upsert(sshEnvFixture());
    server.projectRows.insert(project());
    server.repositoryRows
      ..insert(repository())
      ..insert(
        repository(id: 'r-ssh', environmentId: 'ssh:h1', path: '/srv/app'),
      );
    server.installationRows.insert(agentInstallation());
    dao = server.sessionRows;
    // Also the daemon writing to the server's rows, as `serve` does: these
    // groups follow a row end to end, host write to app signal.
    host = FakeHostLifecycle(server);
    container = ProviderContainer(
      overrides: [
        dataClientProvider.overrideWithValue(data),
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        hostLifecycleSourceProvider.overrideWithValue(host),
        sessionCheckpointRecorderProvider.overrideWith(
          () => recorder = _RecordingRecorder(),
        ),
      ],
    );
    addTearDown(() {
      container.dispose();
      db.close();
    });
  });

  void row(
    String id, {
    SessionStatus status = SessionStatus.running,
    String repositoryId = 'r1',
  }) {
    dao.insert(session(id: id, status: status, repositoryId: repositoryId));
    dao.updateExternalSessionId(id, 'cli-$id');
  }

  SessionStatus statusOf(String id) => dao.getById(id)!.status;

  /// What `AppShell` does: watch it, so it dials.
  Future<void> startWatching() async {
    container.listen(hostLifecycleSubscriberProvider, (_, _) {});
    await _settle();
  }

  AgentStatusReport sessionEnd(String id, String reason) =>
      applyAgentHookCallback(
        container,
        agentId: AgentIds.claudeCode,
        event: 'SessionEnd',
        body: jsonEncode({
          'session_id': 'cli-$id',
          'cwd': r'C:\src\demo',
          'hook_event_name': 'SessionEnd',
          'reason': reason,
        }),
      );

  group('the app is a client of the host\'s record', () {
    late FakeHostLifecycle feedOnly;
    late ProviderContainer client;

    setUp(() {
      feedOnly = FakeHostLifecycle();
      client = ProviderContainer(
        overrides: [
          dataClientProvider.overrideWithValue(data),
          ...fakeTerminalOverrides(database: db),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          hostLifecycleSourceProvider.overrideWithValue(feedOnly),
        ],
      );
      addTearDown(client.dispose);
    });

    Future<void> watch() async {
      client.listen(hostLifecycleSubscriberProvider, (_, _) {});
      await _settle();
    }

    int signal(String id) => client.read(sessionSignalsProvider).forSession(id);

    test('a lifecycle event, and a live claim no host knows, write nothing '
        'here', () async {
      row('s1');
      row('lost');
      feedOnly.snapshot = [hostFacts('s1', HostSessionState.running)];
      await watch();
      feedOnly.link.add(
        hostEvent('s1', SessionLifecycleKind.exited, exitCode: 0, second: 2),
      );
      await _settle();

      expect(statusOf('s1'), SessionStatus.running);
      expect(statusOf('lost'), SessionStatus.running);
      expect(client.read(hostLifecycleSubscriberProvider)!.knows('s1'), isTrue);
    });

    test('a status the server records reaches this app on the data channel, '
        'as a status change for that row alone', () async {
      row('s1');
      row('s2');
      await watch();
      client.read(sessionsDataProvider);
      final before = signal('s1');
      final other = signal('s2');

      // The daemon writes the row; every client is told the row.
      dao.updateStatus('s1', SessionStatus.completed);
      await _settle();

      expect(signal('s1'), greaterThan(before));
      expect(signal('s2'), other);
      expect(
        client.read(sessionsDataProvider).getById('s1')!.status,
        SessionStatus.completed,
      );
    });

    test('the rows this app runs in its own live panes are named on each '
        'watch', () async {
      row('in-app');
      dao.updatePaneId('in-app', 'pane-1');
      row('hosted');
      dao.updatePaneId('hosted', 'pane-2');
      final subscriber = HostLifecycleSubscriber(
        source: feedOnly,
        sessions: dao,
        hasLivePane: (paneId) => paneId == 'pane-1',
      );
      addTearDown(subscriber.dispose);
      subscriber.start();
      await _settle();
      expect(feedOnly.runByClient.single, ['in-app']);
    });
  });

  group('restarting the app', () {
    test('a row the host still runs is running, never unknown', () async {
      row('s1');
      host.snapshot = [hostFacts('s1', HostSessionState.running)];
      // The launch pass leaves this machine's rows to the feed.
      final onThisMachine = container.read(sessionRunsOnThisMachineProvider);
      final sessions = container.read(sessionsDataProvider);
      expect(
        markSessionsLostOnLaunch(sessions, where: (s) => !onThisMachine(s)),
        0,
      );
      await sessions.settled();
      expect(statusOf('s1'), SessionStatus.running);

      await startWatching();

      expect(statusOf('s1'), SessionStatus.running);
    });

    test('a row the host knows as running comes back from unknown', () async {
      row('s1', status: SessionStatus.unknown);
      host.snapshot = [hostFacts('s1', HostSessionState.running)];
      final before = container.read(sessionSignalsProvider).forSession('s1');

      await startWatching();

      expect(statusOf('s1'), SessionStatus.running);
      expect(
        container.read(sessionSignalsProvider).forSession('s1'),
        greaterThan(before),
      );
    });

    test('a live claim no host knows is unknown', () async {
      row('lost');
      await startWatching();
      expect(statusOf('lost'), SessionStatus.unknown);
    });

    test('with no host listening, the app writes nothing: the next host to '
        'start marks what it does not hold', () async {
      row('lost');
      host.listening = false;
      await startWatching();
      expect(statusOf('lost'), SessionStatus.running);
    });

    test('a session on an SSH host is not this host\'s to call lost', () async {
      row('remote', repositoryId: 'r-ssh');
      await startWatching();
      expect(statusOf('remote'), SessionStatus.running);

      // And the launch pass still speaks for it, as before.
      final onThisMachine = container.read(sessionRunsOnThisMachineProvider);
      final sessions = container.read(sessionsDataProvider);
      expect(
        markSessionsLostOnLaunch(sessions, where: (s) => !onThisMachine(s)),
        1,
      );
      await sessions.settled();
      expect(statusOf('remote'), SessionStatus.unknown);
    });
  });

  group('restarting the host', () {
    test('an exit with no code, then the pane starting it again, is running; '
        'Claude\'s SessionEnd in between settles nothing', () async {
      row('s1');
      host.snapshot = [hostFacts('s1', HostSessionState.running)];
      await startWatching();

      host.link.add(
        hostEvent(
          's1',
          SessionLifecycleKind.exited,
          reason: 'host stopped while running',
          second: 2,
        ),
      );
      await _settle();
      // Nobody saw it exit, so it is not a success.
      expect(statusOf('s1'), SessionStatus.unknown);

      // Claude fires this when the restart kills it.
      final report = sessionEnd('s1', 'other');
      expect(report.ending, AgentSessionEnding.completed);
      expect(statusOf('s1'), SessionStatus.unknown);

      // The host goes away and comes back holding the ended session.
      await host.link.close();
      host.snapshot = [
        hostFacts(
          's1',
          HostSessionState.exited,
          reason: 'host stopped while running',
          second: 3,
        ),
      ];
      container.read(hostLifecycleSubscriberProvider)!.nudge();
      await _settle();
      expect(host.links, hasLength(2));
      expect(statusOf('s1'), SessionStatus.unknown);

      host.link.add(hostEvent('s1', SessionLifecycleKind.started, second: 4));
      await _settle();
      expect(statusOf('s1'), SessionStatus.running);
    });

    test('a host that stops answering is only forgotten, not written for; the '
        'one that replaces it marks what it lost', () async {
      row('s1');
      host.snapshot = [hostFacts('s1', HostSessionState.running)];
      await startWatching();
      final subscriber = container.read(hostLifecycleSubscriberProvider)!;

      host.listening = false;
      await host.link.close();
      subscriber.nudge();
      await _settle();
      expect(statusOf('s1'), SessionStatus.running);
      expect(subscriber.isRunning('s1'), isFalse);

      host
        ..listening = true
        ..snapshot = const [];
      subscriber.nudge();
      await _settle();
      expect(statusOf('s1'), SessionStatus.unknown);
    });
  });

  group('how a hosted session ends', () {
    Future<void> endWith(
      String id,
      SessionLifecycleKind kind, {
      int? exitCode,
      bool endedByClose = false,
    }) async {
      host.link.add(
        hostEvent(
          id,
          kind,
          exitCode: exitCode,
          endedByClose: endedByClose,
          second: 5,
        ),
      );
      await _settle();
    }

    setUp(() {
      for (final id in ['closed', 'zero', 'one']) {
        row(id);
      }
      host.snapshot = [
        for (final id in ['closed', 'zero', 'one'])
          hostFacts(id, HostSessionState.running),
      ];
    });

    test('closed on request is cancelled', () async {
      await startWatching();
      await endWith('closed', SessionLifecycleKind.closed, endedByClose: true);
      expect(statusOf('closed'), SessionStatus.cancelled);
    });

    // Found running the app: a host crash, then the pane letting go of the
    // dead session's record, read as the person stopping it.
    test(
      'a crash, then its record let go, is unknown, not cancelled',
      () async {
        await startWatching();
        host.link.add(
          hostEvent(
            'zero',
            SessionLifecycleKind.exited,
            reason: 'host stopped while running',
            second: 5,
          ),
        );
        host.link.add(
          hostEvent(
            'zero',
            SessionLifecycleKind.closed,
            reason: 'host stopped while running',
            second: 6,
          ),
        );
        await _settle();
        expect(statusOf('zero'), SessionStatus.unknown);
      },
    );

    test('exit 0 is completed, exit 1 is failed', () async {
      await startWatching();
      await endWith('zero', SessionLifecycleKind.exited, exitCode: 0);
      await endWith('one', SessionLifecycleKind.exited, exitCode: 1);
      expect(statusOf('zero'), SessionStatus.completed);
      expect(statusOf('one'), SessionStatus.failed);
    });

    test('a hook ending waits for the host to say so', () async {
      await startWatching();
      sessionEnd('zero', 'prompt_input_exit');
      expect(statusOf('zero'), SessionStatus.running);
    });
  });

  group('agent hooks the host relayed', () {
    RelayedAgentHook stop(String id, {required int second, String? pane}) =>
        RelayedAgentHook(
          agentId: AgentIds.claudeCode,
          event: 'Stop',
          body: jsonEncode({
            'session_id': 'cli-$id',
            'hook_event_name': 'Stop',
            'stop_hook_active': false,
          }),
          receivedAt: _at(second),
          paneSessionId: pane,
        );

    AgentStatusReport? reported(String id) => container
        .read(agentHookReportsProvider)
        .latest(AgentIds.claudeCode, 'cli-$id');

    test('a live one runs the same intake as the HTTP route, at the time the '
        'host received it', () async {
      row('s1');
      // What the HTTP route would have made of the same callback.
      final direct = ProviderContainer(
        overrides: [
          dataClientProvider.overrideWithValue(data),
          ...fakeTerminalOverrides(database: db),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          hostLifecycleSourceProvider.overrideWithValue(null),
        ],
      );
      addTearDown(direct.dispose);
      final hook = stop('s1', second: 7, pane: 's1');
      final expected = applyAgentHookCallback(
        direct,
        agentId: hook.agentId,
        event: hook.event,
        body: hook.body,
        paneSessionId: hook.paneSessionId,
      );

      await startWatching();
      host.hookLink.add(hook);
      await _settle();

      final report = reported('s1')!;
      expect(report.status, expected.status);
      expect(report.status, isNot(AgentActivityStatus.unknown));
      expect(report.detail, expected.detail);
      expect(report.observedAt, _at(7));
    });

    test(
      'the snapshot catches up an app that was closed, once per hook',
      () async {
        row('s1');
        host.hookSnapshot = [stop('s1', second: 3, pane: 's1')];
        await startWatching();
        expect(reported('s1')!.observedAt, _at(3));

        // The link drops and comes back holding the same hook: not applied again.
        container.read(agentHookReportsProvider).clear();
        await host.link.close();
        await _settle();
        container.read(hostLifecycleSubscriberProvider)!.nudge();
        await _settle();
        expect(host.links, hasLength(2));
        expect(reported('s1'), isNull);

        // A newer one that arrived while the app was away is.
        host.hookSnapshot = [stop('s1', second: 9, pane: 's1')];
        await host.link.close();
        await _settle();
        container.read(hostLifecycleSubscriberProvider)!.nudge();
        await _settle();
        expect(reported('s1')!.observedAt, _at(9));
      },
    );
  });

  group('a PreToolUse the host relayed', () {
    RelayedAgentHook preToolUse({int? holdId, int second = 5}) =>
        RelayedAgentHook(
          agentId: AgentIds.claudeCode,
          event: 'PreToolUse',
          body: jsonEncode({
            'session_id': 'cli-s1',
            'hook_event_name': 'PreToolUse',
            'tool_name': 'Edit',
            'tool_input': {'file_path': '/repo/main.txt'},
          }),
          receivedAt: _at(second),
          paneSessionId: 's1',
          holdId: holdId,
        );

    test('held, it is replied to only once its checkpoint work is done, and '
        'its tool is not marked unheld', () async {
      row('s1');
      await startWatching();
      container.read(sessionCheckpointRecorderProvider);
      final capture = recorder.capture = Completer<void>();

      host.hookLink.add(preToolUse(holdId: 7));
      await _settle();
      expect(recorder.settledCalls, 1, reason: 'the hold waits on the queue');
      expect(host.replies, isEmpty, reason: 'the capture is still running');

      capture.complete();
      await _settle();
      expect(host.replies, [7]);
      expect(recorder.unheld, isEmpty);
      expect(recorder.expired, isEmpty);
    });

    test('held, for a session this app does not know, it is replied to at '
        'once', () async {
      await startWatching();
      container.read(sessionCheckpointRecorderProvider);
      recorder.capture = Completer<void>();

      host.hookLink.add(preToolUse(holdId: 3));
      await _settle();
      expect(host.replies, [3]);
      expect(recorder.settledCalls, 0);
    });

    test('not held — the host had nobody watching — it is marked unheld and '
        'nothing is replied', () async {
      row('s1');
      host.hookSnapshot = [preToolUse()];
      await startWatching();
      container.read(sessionCheckpointRecorderProvider);

      expect(recorder.unheld, ['s1']);
      expect(recorder.settledCalls, 0);
      expect(host.replies, isEmpty);
    });
  });

  // The daemon keeps what each agent it holds is doing (protocol 7); the app
  // renders that and computes nothing of its own for those sessions.
  group('agent status the host keeps', () {
    HostedAgentStatus said(
      String id,
      AgentActivityStatus status, {
      AgentWaitKind waiting = AgentWaitKind.unrecorded,
      List<String> evidence = const [],
    }) => HostedAgentStatus(
      sessionId: id,
      report: AgentStatusReport(
        agentId: AgentIds.claudeCode,
        sessionId: 'cli-$id',
        status: status,
        source: AgentStatusSource.terminalGrid,
        observedAt: _at(2),
        waiting: waiting,
        evidence: evidence,
      ),
    );

    test('is what the app renders for a session the host holds', () async {
      row('s1');
      host.snapshot = [hostFacts('s1', HostSessionState.running)];
      host.statusSnapshot = [
        said(
          's1',
          AgentActivityStatus.awaitingApproval,
          waiting: AgentWaitKind.approval,
          evidence: const ['Do you want to proceed?'],
        ),
      ];
      await startWatching();
      final registry = container.read(sessionStatusRegistryProvider);
      await registry.cycle();

      final report = registry.reportForOpenId('s1')!;
      expect(report.hasOpenPrompt, isTrue);
      expect(report.evidence, ['Do you want to proceed?']);
      expect(report.sessionId, 'cli-s1', reason: 'keyed as the registry keys');

      // A frame moves it at once, out of turn, as a hook used to.
      final moved = registry.hookChanges.first;
      host.statusLink.add((
        sessionId: 's1',
        status: said('s1', AgentActivityStatus.idle),
      ));
      await _settle();
      expect((await moved).report.status, AgentActivityStatus.idle);

      // A hook the host relayed still runs the intake, but the status is the
      // host's word: it computed its own from the same hook.
      host.hookLink.add(
        RelayedAgentHook(
          agentId: AgentIds.claudeCode,
          event: 'UserPromptSubmit',
          body: jsonEncode({'session_id': 'cli-s1'}),
          receivedAt: _at(3),
          paneSessionId: 's1',
        ),
      );
      await _settle();
      expect(registry.reportForOpenId('s1')!.status, AgentActivityStatus.idle);
    });

    test('a status that moved while the app was closed is what the reopened '
        'app renders', () async {
      row('s1');
      host.snapshot = [hostFacts('s1', HostSessionState.running)];
      host.statusSnapshot = [
        said(
          's1',
          AgentActivityStatus.awaitingApproval,
          waiting: AgentWaitKind.approval,
          evidence: const ['Yes, I trust this folder'],
        ),
      ];
      await startWatching();
      await container.read(sessionStatusRegistryProvider).cycle();
      expect(
        container
            .read(sessionStatusRegistryProvider)
            .reportForOpenId('s1')!
            .status,
        AgentActivityStatus.awaitingApproval,
      );

      // The app quits. The host answers the question, the agent replies and
      // stops; nobody is watching, so all of it is in the next snapshot.
      container.dispose();
      final idle = HostedAgentStatus(
        sessionId: 's1',
        report: AgentStatusReport(
          agentId: AgentIds.claudeCode,
          sessionId: 'cli-s1',
          status: AgentActivityStatus.idle,
          source: AgentStatusSource.hook,
          observedAt: _at(9),
        ),
      );
      host
        ..statusSnapshot = [idle]
        ..hookSnapshot = [
          for (final (i, event) in [
            'SessionStart',
            'UserPromptSubmit',
            'Stop',
          ].indexed)
            RelayedAgentHook(
              agentId: AgentIds.claudeCode,
              event: event,
              body: jsonEncode({
                'session_id': 'cli-s1',
                'hook_event_name': event,
              }),
              receivedAt: _at(6 + i),
              paneSessionId: 's1',
            ),
        ];

      // The app opens again.
      container = ProviderContainer(
        overrides: [
          dataClientProvider.overrideWithValue(data),
          ...fakeTerminalOverrides(database: db),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          hostLifecycleSourceProvider.overrideWithValue(host),
        ],
      );
      await startWatching();
      final registry = container.read(sessionStatusRegistryProvider);
      await registry.cycle();
      await _settle();

      expect(container.read(hostAgentStatusesProvider).of('s1'), isNotNull);
      final report = registry.reportForOpenId('s1')!;
      expect(report.status, AgentActivityStatus.idle);
      expect(report.source, AgentStatusSource.hook);
    });

    // Found live: the app reopened on an agent that had answered and stopped
    // while it was closed, and `session_wait` read `unknown` with no evidence
    // although the host's snapshot said idle. The row joins the watch set
    // only once the host says it runs it, which lands while the registry's
    // first cycle is still on its disk work (store scans, adoption, the CLI
    // store sync); the host's word needs none of that and waited behind it.
    test('a reopened app renders the host\'s snapshot at once, while the '
        'registry\'s first cycle is still on its disk work', () async {
      // The app launches Claude Code with the row id as its session id.
      dao.insert(session(id: 's1', status: SessionStatus.running));
      dao.updateExternalSessionId('s1', 's1');
      host
        ..snapshot = [hostFacts('s1', HostSessionState.running)]
        ..statusSnapshot = [
          HostedAgentStatus(
            sessionId: 's1',
            report: AgentStatusReport(
              agentId: AgentIds.claudeCode,
              sessionId: 's1',
              status: AgentActivityStatus.idle,
              source: AgentStatusSource.hook,
              observedAt: _at(-30),
              detail: 'Stop',
            ),
          ),
        ]
        // The host keeps the latest hook per pane: the Stop.
        ..hookSnapshot = [
          RelayedAgentHook(
            agentId: AgentIds.claudeCode,
            event: 'Stop',
            body: jsonEncode({
              'session_id': 's1',
              'hook_event_name': 'Stop',
              'stop_hook_active': false,
            }),
            receivedAt: _at(-30),
            paneSessionId: 's1',
          ),
        ];
      // A launch's first cycle: its store sync is slow, and still running.
      final storeSync = Completer<void>();
      addTearDown(storeSync.complete);
      final app = ProviderContainer(
        overrides: [
          dataClientProvider.overrideWithValue(data),
          ...fakeTerminalOverrides(database: db),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          hostLifecycleSourceProvider.overrideWithValue(host),
          cliStoreSyncRunnerProvider.overrideWithValue(() => storeSync.future),
        ],
      );
      addTearDown(app.dispose);

      // The registry starts cycling before the host link is up and before
      // the session's pane has reattached: nothing says the row runs yet.
      host.listening = false;
      app.listen(hostLifecycleSubscriberProvider, (_, _) {});
      final registry = app.read(sessionStatusRegistryProvider)..start();
      await _settle();
      expect(registry.reportForOpenId('s1'), isNull);

      // The link comes up with the host's snapshot; the pane reattaches.
      host.listening = true;
      app.read(hostLifecycleSubscriberProvider)!.nudge();
      await _settle();
      expect(app.read(hostLifecycleSubscriberProvider)!.isWatching, isTrue);
      app
          .read(terminalSessionsControllerProvider.notifier)
          .openTab(TerminalProfile.powerShell);
      dao.updatePaneId(
        's1',
        app
            .read(terminalSessionsControllerProvider)
            .tabs
            .last
            .layout
            .panes
            .first,
      );

      final outcome = await app
          .read(sessionWaitProvider)
          .wait('s1', bound: const Duration(seconds: 2));
      expect(
        outcome.state,
        SessionWaitState.idle,
        reason:
            '${outcome.agentStatus.name}/${outcome.source.name}, '
            '${outcome.evidenceAge?.inSeconds}s old',
      );
      expect(outcome.agentStatus, AgentActivityStatus.idle);
      expect(outcome.source, AgentStatusSource.hook);
    });

    test('a link lost leaves none of it standing', () async {
      row('s1');
      host.snapshot = [hostFacts('s1', HostSessionState.running)];
      host.statusSnapshot = [said('s1', AgentActivityStatus.working)];
      await startWatching();
      expect(container.read(hostAgentStatusesProvider).of('s1'), isNotNull);

      await host.link.close();
      await _settle();
      expect(container.read(hostAgentStatusesProvider).of('s1'), isNull);
    });

    test('an answer for a session the host runs is the host\'s', () async {
      row('s1');
      host.snapshot = [hostFacts('s1', HostSessionState.running)];
      await startWatching();

      final answer = await container
          .read(sessionPromptAnswersProvider)
          .answer(const ApprovalAnswerRequest(sessionId: 's1', approve: true));

      expect(answer.answered, 'Yes');
      final asked = host.promptRequests.single as ApprovalAnswerRequest;
      expect(asked.sessionId, 's1');
      expect(asked.approve, isTrue);
    });

    test('a refusal from the host reaches the caller in its words', () async {
      row('s1');
      host.snapshot = [hostFacts('s1', HostSessionState.running)];
      host.answerPrompt = (_) => Future.error(
        const SessionPromptRefusal('this session has no prompt open to answer'),
      );
      await startWatching();

      await expectLater(
        container
            .read(sessionPromptAnswersProvider)
            .answer(
              const ApprovalAnswerRequest(sessionId: 's1', approve: true),
            ),
        throwsA(
          isA<SessionPromptRefusal>().having(
            (r) => r.message,
            'message',
            contains('no prompt open'),
          ),
        ),
      );
    });

    test('a session no host holds is answered by the app, not sent', () async {
      row('s2');
      await startWatching();

      await expectLater(
        container
            .read(sessionPromptAnswersProvider)
            .answer(
              const ApprovalAnswerRequest(sessionId: 's2', approve: true),
            ),
        throwsA(isA<SessionPromptRefusal>()),
      );
      expect(host.promptRequests, isEmpty);
    });
  });

  test('without a feed, a hook ending still settles the row', () async {
    // An in-app or external-terminal session: the hook is all there is.
    final plain = ProviderContainer(
      overrides: [
        dataClientProvider.overrideWithValue(data),
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        hostLifecycleSourceProvider.overrideWithValue(null),
      ],
    );
    addTearDown(plain.dispose);
    row('s1');
    applyAgentHookCallback(
      plain,
      agentId: AgentIds.claudeCode,
      event: 'SessionEnd',
      body: jsonEncode({'session_id': 'cli-s1', 'reason': 'other'}),
    );
    await plain.read(sessionsDataProvider).settled();
    expect(statusOf('s1'), SessionStatus.completed);
  });
}
