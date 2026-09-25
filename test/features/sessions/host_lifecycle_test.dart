import 'dart:async';
import 'dart:convert';

import 'package:agent_cli/descriptors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_hook_intake.dart';
import 'package:karmashala/src/features/agents/application/agent_status_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/checkpoints/application/session_checkpoint_recorder.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_providers.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_source.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/relayed_agent_hook.dart';
import 'package:karmashala/src/features/sessions/application/session_liveness_reconciler.dart';
import 'package:karmashala/src/features/sessions/application/session_signals.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_store/database.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// A host that answers from memory: each [open] is one link, whose events the
/// test pushes and whose end is the host going away.
class _FakeHost implements HostLifecycleSource {
  bool listening = true;
  List<SessionFacts> snapshot = const [];
  List<RelayedAgentHook> hookSnapshot = const [];
  final links = <StreamController<SessionLifecycleEvent>>[];
  final hookLinks = <StreamController<RelayedAgentHook>>[];

  /// The hold ids this app released, in order.
  final replies = <int>[];

  StreamController<SessionLifecycleEvent> get link => links.last;
  StreamController<RelayedAgentHook> get hookLink => hookLinks.last;

  @override
  Future<HostLifecycleFeed?> open() async {
    if (!listening) return null;
    final link = StreamController<SessionLifecycleEvent>();
    final hooks = StreamController<RelayedAgentHook>();
    links.add(link);
    hookLinks.add(hooks);
    return HostLifecycleFeed(
      snapshot: List.of(snapshot),
      events: link.stream,
      hookSnapshot: List.of(hookSnapshot),
      hooks: hooks.stream,
      replyHook: replies.add,
      close: () async {
        if (!link.isClosed) await link.close();
        if (!hooks.isClosed) await hooks.close();
      },
    );
  }
}

DateTime _at(int second) => testTime.add(Duration(seconds: second));

SessionFacts _facts(
  String sessionId,
  HostSessionState state, {
  int? exitCode,
  String? reason,
  int second = 1,
}) => SessionFacts(
  hostSessionId: hostSessionIdOf(sessionId),
  state: state,
  exitCode: exitCode,
  reason: reason,
  observedAt: _at(second),
);

SessionLifecycleEvent _event(
  String sessionId,
  SessionLifecycleKind kind, {
  int? exitCode,
  String? reason,
  bool endedByClose = false,
  required int second,
}) => SessionLifecycleEvent(
  hostSessionId: hostSessionIdOf(sessionId),
  kind: kind,
  exitCode: exitCode,
  reason: reason,
  endedByClose: endedByClose,
  observedAt: _at(second),
);

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
  late SessionDao dao;
  late _FakeHost host;
  late ProviderContainer container;
  late _RecordingRecorder recorder;

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db)
      ..upsert(windowsEnv())
      ..upsert(sshEnvFixture());
    ProjectDao(db).insert(project());
    RepositoryDao(db)
      ..insert(repository())
      ..insert(
        repository(id: 'r-ssh', environmentId: 'ssh:h1', path: '/srv/app'),
      );
    AgentInstallationDao(db).insert(agentInstallation());
    dao = SessionDao(db);
    host = _FakeHost();
    container = ProviderContainer(
      overrides: [
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

  group('restarting the app', () {
    test('a row the host still runs is running, never unknown', () async {
      row('s1');
      host.snapshot = [_facts('s1', HostSessionState.running)];
      // The launch pass leaves this machine's rows to the feed.
      final onThisMachine = container.read(sessionRunsOnThisMachineProvider);
      expect(markSessionsLostOnLaunch(dao, where: (s) => !onThisMachine(s)), 0);
      expect(statusOf('s1'), SessionStatus.running);

      await startWatching();

      expect(statusOf('s1'), SessionStatus.running);
    });

    test('a row the host knows as running comes back from unknown', () async {
      row('s1', status: SessionStatus.unknown);
      host.snapshot = [_facts('s1', HostSessionState.running)];
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

    test('with no host listening, a live claim is unknown too', () async {
      row('lost');
      host.listening = false;
      await startWatching();
      expect(statusOf('lost'), SessionStatus.unknown);
    });

    test('a session on an SSH host is not this host\'s to call lost', () async {
      row('remote', repositoryId: 'r-ssh');
      await startWatching();
      expect(statusOf('remote'), SessionStatus.running);

      // And the launch pass still speaks for it, as before.
      final onThisMachine = container.read(sessionRunsOnThisMachineProvider);
      expect(markSessionsLostOnLaunch(dao, where: (s) => !onThisMachine(s)), 1);
      expect(statusOf('remote'), SessionStatus.unknown);
    });
  });

  group('restarting the host', () {
    test('an exit with no code, then the pane starting it again, is running; '
        'Claude\'s SessionEnd in between settles nothing', () async {
      row('s1');
      host.snapshot = [_facts('s1', HostSessionState.running)];
      await startWatching();

      host.link.add(
        _event(
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
        _facts(
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

      host.link.add(_event('s1', SessionLifecycleKind.started, second: 4));
      await _settle();
      expect(statusOf('s1'), SessionStatus.running);
    });

    test('a host that stops answering takes its running sessions', () async {
      row('s1');
      host.snapshot = [_facts('s1', HostSessionState.running)];
      await startWatching();

      host.listening = false;
      await host.link.close();
      container.read(hostLifecycleSubscriberProvider)!.nudge();
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
        _event(
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
          _facts(id, HostSessionState.running),
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
          _event(
            'zero',
            SessionLifecycleKind.exited,
            reason: 'host stopped while running',
            second: 5,
          ),
        );
        host.link.add(
          _event(
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

  test('without a feed, a hook ending still settles the row', () {
    // An in-app or external-terminal session: the hook is all there is.
    final plain = ProviderContainer(
      overrides: [
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
    expect(statusOf('s1'), SessionStatus.completed);
  });
}
