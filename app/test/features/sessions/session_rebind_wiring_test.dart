import 'dart:convert';

import 'package:agent_cli/descriptors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_hook_intake.dart';
import 'package:karmashala/src/features/agents/application/agent_status_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/session_adoption_service.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala/src/features/sessions/application/session_rebind_providers.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_agent_reporting/hooks.dart';
import 'package:karmashala_session/session.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// **The row a `/clear` left behind.**
///
/// Measured on the owner's machine 2026-09-13: the pane titled `karmashala-2`
/// was bound to a conversation last written two and a half hours earlier, and
/// the one it was really on had never been seen — so the session read as
/// finished while its agent worked. Nothing noticed, because adoption skips
/// any pane the app launched itself.
void main() {
  late AppDatabase db;
  late SessionDao sessions;
  late AgentHookReports reports;

  setUp(() {
    db = AppDatabase.memory();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
    sessions = SessionDao(db);
    reports = AgentHookReports();
  });

  tearDown(() => db.close());

  /// A row in a pane the app launched, on conversation `cli-<id>`.
  void launched(String id, {required String paneId}) {
    sessions.insert(session(id: id, status: SessionStatus.running));
    sessions.updateExternalSessionId(id, 'cli-$id');
    sessions.updatePaneId(id, paneId);
  }

  void heardFrom(String conversationId, DateTime at, {bool ended = false}) =>
      reports.record(
        AgentStatusReport(
          agentId: AgentIds.claudeCode,
          sessionId: conversationId,
          status: ended
              ? AgentActivityStatus.idle
              : AgentActivityStatus.working,
          source: AgentStatusSource.hook,
          observedAt: at,
          ending: ended ? AgentSessionEnding.completed : null,
        ),
      );

  ProviderContainer containerWith(List<String> livePaneIds, {Clock? clock}) {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(clock ?? FixedClock(testTime)),
        agentHookReportsProvider.overrideWithValue(reports),
        adoptablePanesProvider.overrideWithValue(
          () => [
            for (final paneId in livePaneIds)
              AdoptablePane(
                paneId: paneId,
                workingDirectory: r'C:\src\demo\app',
                isLive: true,
                hostsLaunchedSession: true,
              ),
          ],
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  String? rebind(
    ProviderContainer container,
    String conversationId, {
    String? paneSessionId,
    String event = 'UserPromptSubmit',
  }) => rebindSessionFromHook(
    container,
    agentId: AgentIds.claudeCode,
    conversationId: conversationId,
    event: event,
    body: jsonEncode({'session_id': conversationId, 'cwd': r'C:\src\demo\app'}),
    paneSessionId: paneSessionId,
  );

  test('a hook from an unknown conversation re-points the quiet pane', () {
    launched('s1', paneId: 'pane-1');
    final container = containerWith(['pane-1']);

    expect(rebind(container, 'cli-new'), 's1');
    // The row keeps its identity; only the conversation it names changed.
    expect(sessions.getById('s1')!.externalSessionId, 'cli-new');
    expect(sessions.getById('s1')!.paneId, 'pane-1');
    expect(sessions.getById('s1')!.title, 'Work');
  });

  test('a pane still reporting keeps its conversation', () {
    launched('s1', paneId: 'pane-1');
    heardFrom('cli-s1', testTime);
    final container = containerWith(['pane-1']);

    expect(rebind(container, 'cli-new'), isNull);
    expect(sessions.getById('s1')!.externalSessionId, 'cli-s1');
  });

  test('a conversation some row already holds is left alone', () {
    launched('s1', paneId: 'pane-1');
    launched('s2', paneId: 'pane-2');
    final container = containerWith(['pane-1', 'pane-2']);

    expect(rebind(container, 'cli-s2'), isNull);
    expect(sessions.getById('s1')!.externalSessionId, 'cli-s1');
  });

  test('a conversation named after one of our own rows is that row\'s', () {
    // Claude Code is launched with the row id as its session id, so an id that
    // names a row belongs to it — even while that row names something else,
    // which is how one wrong rebind turned into a chain of them.
    launched('s1', paneId: 'pane-1');
    sessions.insert(session(id: 's2', status: SessionStatus.running));
    sessions.updateExternalSessionId('s2', 'cli-elsewhere');
    final container = containerWith(['pane-1']);

    expect(rebind(container, 's2'), isNull);
    expect(sessions.getById('s1')!.externalSessionId, 'cli-s1');
  });

  test('two quiet panes are a coin toss, and nothing is written', () {
    launched('s1', paneId: 'pane-1');
    launched('s2', paneId: 'pane-2');
    final container = containerWith(['pane-1', 'pane-2']);

    expect(rebind(container, 'cli-new'), isNull);
    expect(sessions.getById('s1')!.externalSessionId, 'cli-s1');
    expect(sessions.getById('s2')!.externalSessionId, 'cli-s2');
  });

  test('one pane still reporting leaves the other unambiguous', () {
    launched('s1', paneId: 'pane-1');
    launched('s2', paneId: 'pane-2');
    heardFrom('cli-s1', testTime);
    final clock = MovableClock(testTime);
    final container = containerWith(['pane-1', 'pane-2'], clock: clock);

    // s1 was active a moment before the new conversation appeared, so it may
    // be the pane that moved: nobody is chosen yet.
    expect(rebind(container, 'cli-new'), isNull);
    // Then s1 reports again, alive beside the new conversation — not it.
    clock.advance(const Duration(seconds: 10));
    heardFrom('cli-s1', clock.now);
    expect(rebind(container, 'cli-new'), 's2');
  });

  group('a /clear in one of two panes in one folder (2026-09-21)', () {
    // s1 is the pane that /clear'ed: working until 12 s before the new
    // conversation's first hook. s2 has been idle for fifteen minutes.
    void twoPanes() {
      launched('s1', paneId: 'pane-1');
      launched('s2', paneId: 'pane-2');
      heardFrom('cli-s2', testTime.subtract(const Duration(minutes: 15)));
    }

    test('the pane naming itself takes it, whatever the heuristic says', () {
      twoPanes();
      heardFrom('cli-s1', testTime.subtract(const Duration(seconds: 12)));
      final clock = MovableClock(testTime);
      final container = containerWith(['pane-1', 'pane-2'], clock: clock);

      // Its old conversation has not said it ended yet: held, not guessed.
      expect(rebind(container, 'cli-new', paneSessionId: 's1'), isNull);
      clock.advance(const Duration(seconds: 6));
      heardFrom(
        'cli-s1',
        testTime.subtract(const Duration(seconds: 11)),
        ended: true,
      );
      expect(rebind(container, 'cli-new', paneSessionId: 's1'), 's1');
      expect(sessions.getById('s1')!.externalSessionId, 'cli-new');
      expect(sessions.getById('s2')!.externalSessionId, 'cli-s2');
    });

    test('without an identity, the ending picks the pane that moved', () {
      twoPanes();
      heardFrom(
        'cli-s1',
        testTime.subtract(const Duration(seconds: 12)),
        ended: true,
      );
      final container = containerWith(['pane-1', 'pane-2']);

      expect(rebind(container, 'cli-new'), 's1');
      expect(sessions.getById('s2')!.externalSessionId, 'cli-s2');
    });

    test('without an identity or an ending, the idle pane is never handed '
        'it', () {
      twoPanes();
      heardFrom('cli-s1', testTime.subtract(const Duration(seconds: 12)));
      final container = containerWith(['pane-1', 'pane-2']);

      expect(rebind(container, 'cli-new'), isNull);
      expect(sessions.getById('s1')!.externalSessionId, 'cli-s1');
      expect(sessions.getById('s2')!.externalSessionId, 'cli-s2');
    });

    test('a child agent that inherited the pane\'s id moves nothing', () {
      // The pane's own agent is mid-turn, running `claude -p` in a shell.
      twoPanes();
      heardFrom('cli-s1', testTime.subtract(const Duration(seconds: 2)));
      final container = containerWith(['pane-1', 'pane-2']);

      expect(rebind(container, 'cli-child', paneSessionId: 's1'), isNull);
      expect(sessions.getById('s1')!.externalSessionId, 'cli-s1');
      expect(sessions.getById('s2')!.externalSessionId, 'cli-s2');
    });

    test('an identity naming no candidate row is nobody, not a guess', () {
      twoPanes();
      final container = containerWith(['pane-1', 'pane-2']);

      expect(rebind(container, 'cli-new', paneSessionId: 'gone'), isNull);
      expect(sessions.getById('s2')!.externalSessionId, 'cli-s2');
    });

    test('the intake both transports share hands the identity through', () {
      twoPanes();
      heardFrom(
        'cli-s1',
        testTime.subtract(const Duration(seconds: 12)),
        ended: true,
      );
      final container = containerWith(['pane-1', 'pane-2']);

      applyAgentHookCallback(
        container,
        agentId: AgentIds.claudeCode,
        event: 'UserPromptSubmit',
        body: jsonEncode({'session_id': 'cli-new', 'cwd': r'C:\src\demo\app'}),
        paneSessionId: 's1',
      );

      expect(sessions.getById('s1')!.externalSessionId, 'cli-new');
      expect(sessions.getById('s2')!.externalSessionId, 'cli-s2');
    });

    group('a real /clear through the intake', () {
      void hook(
        ProviderContainer container,
        String event,
        Map<String, Object?> payload, {
        String? paneSessionId,
      }) => applyAgentHookCallback(
        container,
        agentId: AgentIds.claudeCode,
        event: event,
        body: jsonEncode({'cwd': r'C:\src\demo\app', ...payload}),
        paneSessionId: paneSessionId,
      );

      for (final identified in [true, false]) {
        test('moves the conversation, keeps the row running '
            '(${identified ? 'pane named' : 'no identity'})', () {
          twoPanes();
          heardFrom('cli-s1', testTime.subtract(const Duration(seconds: 12)));
          final container = containerWith(['pane-1', 'pane-2']);
          final pane = identified ? 's1' : null;

          hook(container, 'SessionEnd', {
            'session_id': 'cli-s1',
            'reason': 'clear',
          }, paneSessionId: pane);
          expect(sessions.getById('s1')!.status, SessionStatus.running);

          hook(container, 'UserPromptSubmit', {
            'session_id': 'cli-new',
          }, paneSessionId: pane);
          expect(sessions.getById('s1')!.externalSessionId, 'cli-new');
          expect(sessions.getById('s1')!.status, SessionStatus.running);
          expect(sessions.getById('s2')!.externalSessionId, 'cli-s2');
          expect(sessions.getById('s2')!.status, SessionStatus.running);

          // And quitting afterwards still ends the row it moved to.
          hook(container, 'SessionEnd', {
            'session_id': 'cli-new',
            'reason': 'prompt_input_exit',
          }, paneSessionId: pane);
          expect(sessions.getById('s1')!.status, SessionStatus.completed);
        });
      }
    });

    test('a malformed identity is no identity', () {
      launched('s1', paneId: 'pane-1');
      final container = containerWith(['pane-1']);

      expect(rebind(container, 'cli-new', paneSessionId: 'a b;c'), 's1');
    });
  });

  group('a conversation that only announced itself (2026-09-23)', () {
    // A `claude` run by hand in a plain terminal in the same folder, quit
    // before any message: it fired hooks, carried no pane id, and was never
    // written. The quiet pane was re-pointed at it and every resume failed.
    for (final event in ['SessionStart', 'SessionEnd', 'Notification', null]) {
      test('a bare $event moves nothing', () {
        launched('s1', paneId: 'pane-1');
        final container = containerWith(['pane-1']);

        expect(rebind(container, 'cli-ghost', event: event ?? ''), isNull);
        expect(sessions.getById('s1')!.externalSessionId, 'cli-s1');
      });
    }

    test('the same conversation moves the row once it has a turn', () {
      launched('s1', paneId: 'pane-1');
      final container = containerWith(['pane-1']);

      applyAgentHookCallback(
        container,
        agentId: AgentIds.claudeCode,
        event: 'SessionEnd',
        body: jsonEncode({'session_id': 'cli-new', 'cwd': r'C:\src\demo\app'}),
      );
      expect(sessions.getById('s1')!.externalSessionId, 'cli-s1');
      // A moment later, well inside the retry floor: still looked at.
      applyAgentHookCallback(
        container,
        agentId: AgentIds.claudeCode,
        event: 'UserPromptSubmit',
        body: jsonEncode({'session_id': 'cli-new', 'cwd': r'C:\src\demo\app'}),
      );
      expect(sessions.getById('s1')!.externalSessionId, 'cli-new');
    });

    test('a pane naming itself still needs a turn', () {
      launched('s1', paneId: 'pane-1');
      final container = containerWith(['pane-1']);

      expect(
        rebind(
          container,
          'cli-ghost',
          paneSessionId: 's1',
          event: 'SessionEnd',
        ),
        isNull,
      );
      expect(sessions.getById('s1')!.externalSessionId, 'cli-s1');
      expect(rebind(container, 'cli-ghost', paneSessionId: 's1'), 's1');
    });
  });

  test('a pane with no live session of ours is nothing to re-point', () {
    launched('s1', paneId: 'pane-1');
    final container = containerWith(const []);

    expect(rebind(container, 'cli-new'), isNull);
  });

  test('the same unknown conversation is not re-examined every callback', () {
    launched('s1', paneId: 'pane-1');
    launched('s2', paneId: 'pane-2');
    final container = containerWith(['pane-1', 'pane-2']);

    // Refused: two quiet panes. The second callback arrives a moment later and
    // must cost a map lookup, not another pane list and another query.
    expect(rebind(container, 'cli-new'), isNull);
    heardFrom('cli-s1', testTime);
    expect(rebind(container, 'cli-new'), isNull);
  });
}
