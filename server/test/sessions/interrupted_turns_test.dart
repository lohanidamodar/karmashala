import 'dart:async';
import 'dart:convert';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart'
    show HostedAgentStatus;
import 'package:karmashala_host/src/sessions/interrupted_turns.dart';
import 'package:karmashala_host_protocol/protocol.dart'
    show LifecycleEvent, LifecycleEventKind, SessionEndedWithoutCode;
import 'package:karmashala_session/lineage.dart';
import 'package:karmashala_session/session.dart';
import 'package:test/test.dart';

void main() {
  final t0 = DateTime.utc(2026, 10, 3, 12);

  String? stored;
  OpenTurns turns() => OpenTurns(
    read: () => stored,
    write: (value) => stored = value,
  );

  setUp(() => stored = null);

  Session row(
    String id, {
    SessionStatus status = SessionStatus.unknown,
    String? conversation = 'conv',
    DateTime? archivedAt,
    String? parent,
    SessionLink? link,
  }) => Session(
    id: id,
    repositoryId: 'r1',
    agentInstallationId: 'a1',
    title: 'Row $id',
    useWorktree: false,
    status: status,
    createdAt: t0,
    externalSessionId: conversation,
    archivedAt: archivedAt,
    parentSessionId: parent,
    parentLink: link,
  );

  group('recording a turn as open', () {
    test('working and awaiting approval open it; idle and failed settle it, '
        'and the record is written through', () {
      final open = turns();
      open.statusMoved('s1', AgentActivityStatus.working, t0);
      open.statusMoved('s2', AgentActivityStatus.awaitingApproval, t0);
      open.statusMoved('s3', AgentActivityStatus.working, t0);
      expect(turns().open.keys, {'s1', 's2', 's3'});
      open.statusMoved('s1', AgentActivityStatus.idle, t0);
      open.statusMoved('s2', AgentActivityStatus.failed, t0);
      open.statusMoved('s3', AgentActivityStatus.unknown, t0);
      expect(turns().open.keys, {'s3'});
    });

    test('a turn keeps the moment it opened', () {
      final open = turns();
      open.statusMoved('s1', AgentActivityStatus.working, t0);
      open.statusMoved(
        's1',
        AgentActivityStatus.awaitingApproval,
        t0.add(const Duration(minutes: 5)),
      );
      expect(turns().open['s1']!.since, t0);
    });

    test('an end of the server\'s own keeps the turn; any other end '
        'settles it', () {
      final open = turns();
      for (final id in ['s1', 's2', 's3', 's4']) {
        open.statusMoved(id, AgentActivityStatus.working, t0);
      }
      open.ended(
        'karmashala_s1',
        reason: SessionEndedWithoutCode.hostStopped,
      );
      open.ended(
        'karmashala_s2',
        reason: SessionEndedWithoutCode.hostStoppedWhileRunning,
      );
      open.ended('karmashala_s3', reason: 'closed on request');
      open.ended('karmashala_s4');
      expect(turns().open.keys, {'s1', 's2'});
    });

    test('statuses of sessions another host runs are not recorded', () async {
      final open = turns();
      final statuses = StreamController<HostedAgentStatus>.broadcast(
        sync: true,
      );
      final lifecycle = StreamController<LifecycleEvent>.broadcast(sync: true);
      final follow = followOpenTurns(
        open,
        statuses: statuses.stream,
        lifecycle: lifecycle.stream,
        runsHere: (id) => id != 'box',
        clock: () => t0,
      );
      HostedAgentStatus status(String id, AgentActivityStatus s) =>
          HostedAgentStatus(
            sessionId: id,
            report: AgentStatusReport(
              agentId: 'claude-code',
              sessionId: id,
              status: s,
              source: AgentStatusSource.hook,
              observedAt: t0,
            ),
          );
      statuses
        ..add(status('s1', AgentActivityStatus.working))
        ..add(status('box', AgentActivityStatus.working));
      lifecycle.add(
        LifecycleEvent(
          sessionId: 'karmashala_s1',
          kind: LifecycleEventKind.started,
          observedAt: t0,
        ),
      );
      expect(open.open.keys, {'s1'});
      lifecycle.add(
        LifecycleEvent(
          sessionId: 'karmashala_s1',
          kind: LifecycleEventKind.exited,
          exitCode: 0,
          observedAt: t0,
        ),
      );
      expect(open.open, isEmpty);
      for (final subscription in follow) {
        await subscription.cancel();
      }
      await statuses.close();
      await lifecycle.close();
    });

    test('an unreadable record reads as no open turns', () {
      stored = 'not json';
      expect(turns().open, isEmpty);
      stored = jsonEncode({
        's1': {'since': 'never'},
        's2': {'since': t0.toIso8601String()},
      });
      expect(turns().open.keys, {'s2'});
    });
  });

  group('which cut-off turns are continued', () {
    InterruptedTurnPlan plan(
      Map<String, Session> rows, {
      Map<String, OpenTurn>? open,
      Map<String, List<Session>> children = const {},
      Set<String> running = const {},
      DateTime? now,
    }) => planInterruptedTurns(
      open ?? {for (final id in rows.keys) id: OpenTurn(since: t0)},
      sessionOf: (id) => rows[id],
      childrenOf: (id) => children[id] ?? const [],
      runsHere: running.contains,
      now: now ?? t0.add(const Duration(minutes: 1)),
    );

    test('a terminal row left unknown and an ACP row left completed — '
        'a graceful stop and a crash alike — are continued', () {
      final decided = plan({
        'pty': row('pty'),
        'acp': row('acp', status: SessionStatus.completed),
        'crashed': row('crashed', status: SessionStatus.running),
      });
      expect(decided.resume.map((r) => r.sessionId), [
        'pty',
        'acp',
        'crashed',
      ]);
      expect(decided.skipped, isEmpty);
    });

    test('ended on purpose, archived, handed off or gone is left alone', () {
      final decided = plan(
        {
          'stopped': row('stopped', status: SessionStatus.cancelled),
          'failed': row('failed', status: SessionStatus.failed),
          'archived': row('archived', archivedAt: t0),
          'handed': row('handed'),
          'forked': row('forked'),
        },
        open: {
          for (final id in [
            'stopped',
            'failed',
            'archived',
            'handed',
            'forked',
            'gone',
          ])
            id: OpenTurn(since: t0),
        },
        children: {
          'handed': [row('next', parent: 'handed', link: SessionLink.handoff)],
          'forked': [row('branch', parent: 'forked', link: SessionLink.fork)],
        },
      );
      expect(decided.resume.map((r) => r.sessionId), ['forked']);
      expect({for (final s in decided.skipped) s.sessionId: s.reason}, {
        'stopped': 'it was stopped',
        'failed': 'it ended in error',
        'archived': 'it was archived',
        'handed': 'its work was handed off',
        'gone': 'it is no longer in the workspace',
      });
    });

    test('running already, no conversation, too old or looping is skipped', () {
      final decided = plan(
        {
          'live': row('live', status: SessionStatus.running),
          'nameless': row('nameless', conversation: null),
          'old': row('old'),
          'loop': row('loop'),
        },
        open: {
          'live': OpenTurn(since: t0),
          'nameless': OpenTurn(since: t0),
          'old': OpenTurn(since: t0.subtract(const Duration(hours: 13))),
          'loop': OpenTurn(since: t0, continues: kMaxAutomaticContinues),
        },
        running: {'live'},
      );
      expect(decided.resume, isEmpty);
      expect(decided.skipped.map((s) => s.sessionId), [
        'live',
        'nameless',
        'old',
        'loop',
      ]);
    });
  });

  group('continuing at boot', () {
    late Map<String, Session> rows;
    late List<(String, String?)> resumed;
    late List<String> logged;

    InterruptedTurnContinuer continuer(
      OpenTurns open, {
      bool enabled = true,
      bool Function(Session)? takes,
      Future<void> Function(String id, String? prompt)? resume,
    }) => InterruptedTurnContinuer(
      turns: open,
      sessionOf: (id) => rows[id],
      childrenOf: (_) => const [],
      runsHere: (_) => false,
      takesOpeningMessage: takes ?? (_) => true,
      resume:
          resume ??
          (id, prompt) async {
            resumed.add((id, prompt));
          },
      now: () => t0.add(const Duration(minutes: 1)),
      enabled: () => enabled,
      log: logged.add,
    );

    setUp(() {
      rows = {'s1': row('s1'), 's2': row('s2')};
      resumed = [];
      logged = [];
    });

    test('each cut-off turn is resumed with the prompt, its record cleared '
        'before the resume starts', () async {
      final open = turns()
        ..statusMoved('s1', AgentActivityStatus.working, t0)
        ..statusMoved('s2', AgentActivityStatus.working, t0);
      String? recordWhenResumed;
      final run = continuer(
        open,
        resume: (id, prompt) async {
          recordWhenResumed = stored;
          resumed.add((id, prompt));
        },
      );
      expect(await run.run(), ['s1', 's2']);
      expect(resumed, [
        ('s1', kInterruptedTurnPrompt),
        ('s2', kInterruptedTurnPrompt),
      ]);
      expect(jsonDecode(recordWhenResumed!), isEmpty);
    });

    test('every resume is started before the first one finishes', () async {
      final open = turns()
        ..statusMoved('s1', AgentActivityStatus.working, t0)
        ..statusMoved('s2', AgentActivityStatus.working, t0);
      final gate = Completer<void>();
      final started = <String>[];
      final run = continuer(
        open,
        resume: (id, prompt) {
          started.add(id);
          return gate.future;
        },
      ).run();
      expect(started, ['s1', 's2']);
      gate.complete();
      await run;
    });

    test('once per boot: a second run and a second server find nothing', () async {
      final open = turns()..statusMoved('s1', AgentActivityStatus.working, t0);
      final run = continuer(open);
      await run.run();
      await run.run();
      await continuer(turns()).run();
      expect(resumed, hasLength(1));
    });

    test('a resume that fails is not tried again', () async {
      final open = turns()..statusMoved('s1', AgentActivityStatus.working, t0);
      expect(
        await continuer(
          open,
          resume: (_, _) async => throw StateError('no agent'),
        ).run(),
        isEmpty,
      );
      expect(turns().open, isEmpty);
      expect(logged.single, contains('could not be resumed'));
    });

    test('the continued turn is counted, and a run of them stops', () async {
      var open = turns()..statusMoved('s1', AgentActivityStatus.working, t0);
      for (var i = 0; i < kMaxAutomaticContinues; i++) {
        await continuer(open).run();
        // The continued turn starts, and the server dies in it again.
        open.statusMoved('s1', AgentActivityStatus.working, t0);
        open = turns();
      }
      expect(open.open['s1']!.continues, kMaxAutomaticContinues);
      await continuer(open).run();
      expect(resumed, hasLength(kMaxAutomaticContinues));
      expect(logged.last, contains('automatic continues'));
    });

    test('a turn that settles resets the count', () async {
      final open = turns()..statusMoved('s1', AgentActivityStatus.working, t0);
      await continuer(open).run();
      open
        ..statusMoved('s1', AgentActivityStatus.working, t0)
        ..statusMoved('s1', AgentActivityStatus.idle, t0)
        ..statusMoved('s1', AgentActivityStatus.working, t0);
      expect(turns().open['s1']!.continues, 0);
    });

    test('an agent that takes no opening message is resumed untold, and '
        'the log says so', () async {
      final open = turns()..statusMoved('s1', AgentActivityStatus.working, t0);
      await continuer(open, takes: (_) => false).run();
      expect(resumed, [('s1', null)]);
      expect(logged.single, contains('not told'));
    });

    test('switched off: nothing is resumed and the record is cleared', () async {
      final open = turns()..statusMoved('s1', AgentActivityStatus.working, t0);
      await continuer(open, enabled: false).run();
      expect(resumed, isEmpty);
      expect(turns().open, isEmpty);
      expect(logged.single, contains('switched off'));
    });
  });

  group('the setting', () {
    test('on unless settings.v1 says false', () {
      expect(continuesInterruptedTurns(null), isTrue);
      expect(continuesInterruptedTurns('garbage'), isTrue);
      expect(continuesInterruptedTurns('{}'), isTrue);
      expect(
        continuesInterruptedTurns('{"continueInterruptedTurns": true}'),
        isTrue,
      );
      expect(
        continuesInterruptedTurns('{"continueInterruptedTurns": false}'),
        isFalse,
      );
    });
  });
}
