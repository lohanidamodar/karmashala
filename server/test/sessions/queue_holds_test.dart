import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_automations/resumes.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show DataRefusalCode, DataRefused;
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/acp/acp_usage_limit.dart'
    show kProtocolUsageLimitReason;
import 'package:karmashala_host/src/automations/server_usage_limits.dart';
import 'package:karmashala_host/src/sessions/session_queue.dart';
import 'package:karmashala_host/src/status/daemon_agent_status.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// What holds a queue past its turn's end, and how a resume sends through
/// it rather than beside it.
void main() {
  final t0 = DateTime.utc(2026, 10, 3, 12);
  final resetAt = t0.add(const Duration(hours: 2));

  late AppDatabase database;
  late SessionRegistry registry;
  late FakePtyLauncher launcher;
  late DaemonAgentStatus status;
  late SessionQueueDao dao;
  late List<List<QueuedMessage>> announced;
  late List<String> delivered;
  late SessionQueue queue;
  ScheduledResume? live;

  ScheduledResume resumeAt(DateTime fireAt, {String? window = '5-hour'}) =>
      ScheduledResume(
        id: 'resume1',
        sessionId: 's1',
        fireAt: fireAt,
        state: ScheduledResumeState.pending,
        scheduledAt: t0,
        message: 'continue',
        windowLabel: window,
      );

  setUp(() {
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
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
    status = DaemonAgentStatus(
      registry: registry,
      database: database,
      publish: (_, _) {},
      interval: const Duration(hours: 1),
    );
    dao = SessionQueueDao(database);
    announced = [];
    delivered = [];
    live = null;
    var n = 0;
    queue = SessionQueue(
      dao: dao,
      status: status,
      limitHold: (sessionId) => usageLimitQueueHold(
        live: live,
        report: status.statusOf(sessionId)?.report,
        agentId: AgentIds.claudeCode,
      ),
      announce: (_, open) => announced.add(open),
      turnStartGrace: const Duration(seconds: 30),
      quietPeriod: const Duration(seconds: 30),
      quietPoll: const Duration(milliseconds: 10),
      newId: () => 'q${++n}',
      now: () => t0,
    )..deliver = ((_, text) async => delivered.add(text));
    queue.start();
  });

  tearDown(() async {
    await queue.close();
    await status.close();
    for (final handle in launcher.handles) {
      handle.finish(0);
    }
    await registry.shutdown();
    database.close();
  });

  Future<void> runAgent() async {
    final text = File(
      '../app/test/features/agents/fixtures/claude-code-tui.raw',
    ).readAsStringSync();
    final teardown = text.indexOf('Session terminated');
    registry.open(
      'karmashala_s1',
      PtySpawnRequest(
        argv: const ['claude'],
        workingDirectory: '/src/shop/api',
        environment: const {},
        columns: 120,
        rows: 30,
      ),
    );
    launcher.handles.last.emit(
      utf8.encode(teardown < 0 ? text : text.substring(0, teardown)),
    );
    await pumpEventQueue();
    status.tick();
  }

  void hook(String event, [Map<String, Object?> extra = const {}]) =>
      status.hook(
        AgentHookEvent(
          agent: AgentIds.claudeCode,
          event: event,
          sessionHeader: 's1',
          receivedAt: DateTime.now().toUtc(),
          body: {'session_id': 'conv-1', 'hook_event_name': event, ...extra},
        ),
      );

  QueueAdmission send(String text) =>
      queue.admit('s1', text, origin: QueuedMessageOrigin.app);

  group('a usage limit', () {
    test('a turn that failed on the limit holds the queue rather than '
        'spending it, and says so', () async {
      await runAgent();
      hook('UserPromptSubmit');
      send('a');
      send('b');
      hook('StopFailure', {'error': 'rate_limit'});
      await pumpEventQueue();

      expect(delivered, isEmpty);
      expect(
        announced.last.map((m) => m.hold),
        everyElement(const QueueHold(QueueHoldKind.limit)),
      );
      expect(queue.list('s1').first.hold?.kind, QueueHoldKind.limit);
    });

    test('a failure for another reason still lets the next go', () async {
      await runAgent();
      hook('UserPromptSubmit');
      send('a');
      hook('StopFailure', {'error': 'server_error'});
      await pumpEventQueue();
      expect(delivered, ['a']);
    });

    test('an armed resume holds even a new message, and names its '
        'time', () async {
      await runAgent();
      hook('Stop');
      live = resumeAt(resetAt);
      final admitted = send('after the reset, please');
      expect(admitted, isA<AdmitQueued>());
      await pumpEventQueue();
      expect(delivered, isEmpty);
      expect(
        announced.last.single.hold,
        QueueHold(QueueHoldKind.limit, until: resetAt),
      );
    });

    test('a resume at a chosen time is told as scheduled', () async {
      await runAgent();
      hook('Stop');
      live = resumeAt(resetAt, window: null);
      send('later');
      await pumpEventQueue();
      expect(announced.last.single.hold?.kind, QueueHoldKind.scheduled);
    });

    test(
      'the hold lifts when the resume ends, and the queue goes on',
      () async {
        await runAgent();
        hook('UserPromptSubmit');
        send('a');
        live = resumeAt(resetAt);
        hook('Stop');
        await pumpEventQueue();
        expect(delivered, isEmpty);

        live = null;
        queue.refreshAll();
        await pumpEventQueue();
        expect(delivered, ['a']);
        expect(announced.last, isEmpty);
      },
    );
  });

  group('a resume sends through the queue', () {
    test('the head goes in the resume message\'s place; the rest follow '
        'one per turn once it ends', () async {
      await runAgent();
      hook('UserPromptSubmit');
      send('a');
      send('b');
      live = resumeAt(resetAt);
      hook('StopFailure', {'error': 'rate_limit'});
      await pumpEventQueue();
      expect(delivered, isEmpty);

      expect(await queue.sendForResume('s1', 'continue'), 'a');
      expect(delivered, ['a']);
      live = null;
      queue.refreshAll();
      await pumpEventQueue();
      expect(delivered, ['a'], reason: 'the turn "a" opened still runs');

      hook('UserPromptSubmit');
      hook('Stop');
      await pumpEventQueue();
      expect(delivered, ['a', 'b']);
    });

    test('with nothing queued the resume\'s own message goes', () async {
      await runAgent();
      hook('Stop');
      live = resumeAt(resetAt);
      expect(await queue.sendForResume('s1', 'continue'), 'continue');
      expect(delivered, ['continue']);
      expect(queue.busy('s1'), isTrue, reason: 'its turn is awaited');
    });

    test('a message refused at the agent is said in words', () async {
      await runAgent();
      hook('Stop');
      queue.deliver = (_, _) async => throw const DataRefused(
        DataRefusalCode.conflict,
        'the session has an approval prompt open',
      );
      await expectLater(
        queue.sendForResume('s1', 'continue'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('approval prompt'),
          ),
        ),
      );
    });

    test('a claimed head opens a resumed start; one that did not start '
        'goes back to the front', () async {
      dao.enqueue(
        id: 'h',
        sessionId: 's1',
        text: 'the head',
        origin: QueuedMessageOrigin.app,
        now: t0,
      );
      final claimed = queue.claimHeadForResume('s1')!;
      expect(claimed.text, 'the head');
      expect(dao.getById('h')!.state, QueuedMessageState.delivering);
      expect(queue.claimHeadForResume('s1'), isNull);

      queue.releaseClaimed(claimed, sent: false);
      expect(dao.getById('h')!.state, QueuedMessageState.queued);

      queue.releaseClaimed(queue.claimHeadForResume('s1')!, sent: true);
      expect(dao.getById('h')!.state, QueuedMessageState.delivered);
    });
  });

  group('endedOnUsageLimit', () {
    AgentStatusReport report(
      AgentActivityStatus kind, {
      String? reason,
      AgentStatusSource source = AgentStatusSource.hook,
    }) => AgentStatusReport(
      agentId: AgentIds.claudeCode,
      sessionId: 'conv-1',
      status: kind,
      observedAt: t0,
      source: source,
      failureReason: reason,
    );

    test('reads the agent\'s own word, by its adapter', () {
      expect(
        endedOnUsageLimit(
          report(AgentActivityStatus.failed, reason: 'rate_limit'),
          agentId: AgentIds.claudeCode,
        ),
        isTrue,
      );
      expect(
        endedOnUsageLimit(
          report(AgentActivityStatus.failed, reason: 'server_error'),
          agentId: AgentIds.claudeCode,
        ),
        isFalse,
      );
      expect(
        endedOnUsageLimit(
          report(AgentActivityStatus.idle, reason: 'rate_limit'),
          agentId: AgentIds.claudeCode,
        ),
        isFalse,
      );
      expect(
        endedOnUsageLimit(
          report(
            AgentActivityStatus.failed,
            reason: kProtocolUsageLimitReason,
            source: AgentStatusSource.protocol,
          ),
        ),
        isTrue,
      );
    });
  });
}
