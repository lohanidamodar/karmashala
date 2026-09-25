import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_hook_intake.dart';
import 'package:karmashala_agent_reporting/hooks.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/follow_ups/domain/session_ending.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_outcome_writer.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_session/session.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// **A finished session's row said `running`, for ever.**
///
/// Nothing wrote the six terminal words for a pane-hosted session:
/// `SessionEngine` writes them and no in-app session uses it, and the only
/// other transition a row ever made was `SessionLivenessReconciler` taking a
/// stale claim out to `unknown`.
///
/// The fix everyone reaches for first is the pane's exit code, and it is the
/// wrong one: `endingOfPaneExit` reads exit **0** and nothing else precisely
/// because a Ctrl-C, a `wsl.exe` wrapper that died before the CLI started and a
/// finished conversation are one number. So the status is written from what the
/// **agent states about itself** — and from nothing else. These tests are the
/// per-CLI, per-ending table of what each one can say.
void main() {
  group('what each CLI can say about its own ending', () {
    late AgentHookReceiver receiver;

    setUp(() {
      receiver = AgentHookReceiver(
        registry: AgentRegistry.builtIn,
        reports: AgentHookReports(),
        clock: FixedClock(testTime),
      );
    });

    AgentSessionEnding? endingOf(
      String agentId,
      String event, {
      Map<String, Object?> payload = const {},
    }) => receiver
        .handle(
          agentId: agentId,
          event: event,
          body: jsonEncode({
            'session_id': 'cli-1',
            'conversationId': 'cli-1',
            ...payload,
          }),
        )
        .ending;

    AgentActivityStatus statusOf(String agentId, String event) => receiver
        .handle(
          agentId: agentId,
          event: event,
          body: jsonEncode({'session_id': 'cli-1', 'conversationId': 'cli-1'}),
        )
        .status;

    test('Claude Code: only the CLI leaving finishes the session', () {
      expect(
        endingOf(AgentIds.claudeCode, 'SessionEnd'),
        AgentSessionEnding.completed,
      );
    });

    test('Claude Code: a /clear or /resume ends only the conversation', () {
      for (final reason in ['clear', 'resume']) {
        expect(
          endingOf(
            AgentIds.claudeCode,
            'SessionEnd',
            payload: {'reason': reason},
          ),
          AgentSessionEnding.conversationOnly,
          reason: reason,
        );
      }
    });

    test('Claude Code: every genuine exit still finishes the session', () {
      for (final reason in ['prompt_input_exit', 'logout', 'other', 'new']) {
        expect(
          endingOf(
            AgentIds.claudeCode,
            'SessionEnd',
            payload: {'reason': reason},
          ),
          AgentSessionEnding.completed,
          reason: reason,
        );
      }
    });

    test('Codex: its hard-coded "other" is a real exit', () {
      expect(
        endingOf(AgentIds.codex, 'SessionEnd', payload: {'reason': 'other'}),
        AgentSessionEnding.completed,
      );
    });

    test('Claude Code: a turn ending is not a session ending', () {
      // `Stop` fires once per turn and many times a session; the tool events
      // and `Notification` are mid-turn by construction. `StopFailure` fires
      // *instead of* `Stop` when an API error broke the turn — same cadence,
      // and the session carries on, so it may not end the row either.
      for (final event in [
        'Stop',
        'StopFailure',
        'UserPromptSubmit',
        'PreToolUse',
        'PostToolUse',
        'Notification',
      ]) {
        expect(endingOf(AgentIds.claudeCode, event), isNull, reason: event);
      }
    });

    test('Claude Code: a broken turn is still shown as a failure', () {
      // The row keeps its word; the *live* status says the turn broke, which
      // is what raises attention. Losing that would trade one bug for another.
      expect(
        statusOf(AgentIds.claudeCode, 'StopFailure'),
        AgentActivityStatus.failed,
      );
    });

    test('Codex: SessionEnd finishes, and nothing can say failed', () {
      expect(
        endingOf(AgentIds.codex, 'SessionEnd'),
        AgentSessionEnding.completed,
      );
      for (final event in [
        'Stop',
        'UserPromptSubmit',
        'PreToolUse',
        'PostToolUse',
      ]) {
        expect(endingOf(AgentIds.codex, event), isNull, reason: event);
      }
      // The measured gap, asserted rather than left to a comment:
      // `run_turn_stop_hooks` is called only from the success branch of a turn,
      // so a Codex turn that died fires no hook at all. There is no event to
      // declare, and the row keeps what it had.
      final codex = AgentRegistry.builtIn.byId(AgentIds.codex)!.hooks!;
      expect(
        codex.eventEnding.values,
        isNot(contains(AgentSessionEnding.failed)),
      );
    });

    test('Antigravity: Stop fails only where terminationReason says so', () {
      const failing = [
        'ERROR',
        'MAX_INVOCATIONS',
        'MAX_FORCED_INVOCATIONS',
        'MAX_TOKEN_BUDGET_EXCEEDED',
      ];
      for (final reason in failing) {
        expect(
          endingOf(
            AgentIds.antigravity,
            'Stop',
            payload: {'terminationReason': reason},
          ),
          AgentSessionEnding.failed,
          reason: reason,
        );
      }
      // An ordinary turn, and the user's own stop. Neither ends the session,
      // and `USER_CANCELED` is already written by whoever performed the stop.
      for (final reason in ['NO_TOOL_CALL', 'USER_CANCELED']) {
        expect(
          endingOf(
            AgentIds.antigravity,
            'Stop',
            payload: {'terminationReason': reason},
          ),
          isNull,
          reason: reason,
        );
      }
      // One of the six undeclared reasons. An unrecognised subtype must not be
      // able to invent an ending, for the same reason it does not invent a
      // status.
      expect(
        endingOf(
          AgentIds.antigravity,
          'Stop',
          payload: {'terminationReason': 'HALTED_STEP'},
        ),
        isNull,
      );
      // No `SessionEnd` is installed for Antigravity at all, so its clean
      // finish is simply not reported — and the row says so rather than
      // claiming one.
      expect(endingOf(AgentIds.antigravity, 'PostInvocation'), isNull);
    });
  });

  group('writing the row', () {
    late AppDatabase db;
    late SessionDao dao;
    late SessionOutcomeWriter writer;

    setUp(() {
      db = AppDatabase.memory();
      ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
      ProjectDao(db).insert(project());
      RepositoryDao(db).insert(repository());
      AgentInstallationDao(db).insert(agentInstallation());
      dao = SessionDao(db);
      writer = SessionOutcomeWriter(sessionDao: dao);
    });

    tearDown(() => db.close());

    void live(String id, {SessionStatus status = SessionStatus.running}) {
      dao.insert(session(id: id, status: status));
      dao.updateExternalSessionId(id, 'cli-$id');
    }

    SessionStatus statusOf(String id) => dao.getById(id)!.status;

    test('a stated ending is what moves the row', () {
      live('s1');
      expect(
        writer.record(
          agentSessionId: 'cli-s1',
          ending: AgentSessionEnding.completed,
        ),
        's1',
      );
      expect(statusOf('s1'), SessionStatus.completed);

      live('s2');
      writer.record(
        agentSessionId: 'cli-s2',
        ending: AgentSessionEnding.failed,
      );
      expect(statusOf('s2'), SessionStatus.failed);
      expect(writer.written, 2);
    });

    test('no ending, no write — the row keeps what it had', () {
      live('s1');
      expect(writer.record(agentSessionId: 'cli-s1', ending: null), isNull);
      expect(statusOf('s1'), SessionStatus.running);
      expect(writer.written, 0);
    });

    test('a row that lost its process may still be told how it ended', () {
      // The spool crosses `\\wsl.localhost` and is drained after the fact, so
      // `unknown` — the reconciler's admission — is exactly the row a late
      // payload improves on.
      live('s1', status: SessionStatus.unknown);
      writer.record(
        agentSessionId: 'cli-s1',
        ending: AgentSessionEnding.completed,
      );
      expect(statusOf('s1'), SessionStatus.completed);
    });

    test("the user's own stop is never overwritten", () {
      live('s1', status: SessionStatus.cancelled);
      expect(
        writer.record(
          agentSessionId: 'cli-s1',
          ending: AgentSessionEnding.completed,
        ),
        isNull,
      );
      expect(statusOf('s1'), SessionStatus.cancelled);
    });

    test('a failure is not smoothed away by the exit that follows it', () {
      // Whoever stated the failure stated it about the session; the CLI's
      // later "I am leaving" must not turn it into "finished".
      live('s1');
      writer.record(
        agentSessionId: 'cli-s1',
        ending: AgentSessionEnding.failed,
      );
      writer.record(
        agentSessionId: 'cli-s1',
        ending: AgentSessionEnding.completed,
      );
      expect(statusOf('s1'), SessionStatus.failed);
      expect(writer.written, 1);
    });

    test('a conversation with no row of ours writes nothing', () {
      expect(
        writer.record(
          agentSessionId: 'somebody-elses',
          ending: AgentSessionEnding.completed,
        ),
        isNull,
      );
    });

    test('a pane exit is still not an ending anything writes', () {
      // The refusal this whole change is built around, pinned where a future
      // reader will look for it: exit 0 buys a follow-up's `completed` and
      // never a row status, and every other code buys nothing at all.
      expect(endingOfPaneExit(0), SessionEnding.completed);
      expect(endingOfPaneExit(1), isNull);
      expect(endingOfPaneExit(null), isNull);

      live('s1');
      // Nothing in the writer takes an exit code, so there is no path from one
      // to a row. The row is untouched by the pane's whole vocabulary.
      expect(statusOf('s1'), SessionStatus.running);
    });

    test('a hook callback carries the ending all the way to the row', () {
      live('s1');
      final container = ProviderContainer(
        overrides: [
          ...fakeTerminalOverrides(database: db),
          clockProvider.overrideWithValue(FixedClock(testTime)),
        ],
      );
      addTearDown(container.dispose);

      final report = applyAgentHookCallback(
        container,
        agentId: AgentIds.claudeCode,
        event: 'SessionEnd',
        body: jsonEncode({'session_id': 'cli-s1', 'cwd': r'C:\src\demo'}),
      );

      expect(report.ending, AgentSessionEnding.completed);
      expect(statusOf('s1'), SessionStatus.completed);
    });

    test('a conversation-only ending writes nothing', () {
      live('s1');
      expect(
        writer.record(
          agentSessionId: 'cli-s1',
          ending: AgentSessionEnding.conversationOnly,
        ),
        isNull,
      );
      expect(statusOf('s1'), SessionStatus.running);
      expect(writer.written, 0);
    });

    group('through the hook intake', () {
      late ProviderContainer container;

      setUp(() {
        container = ProviderContainer(
          overrides: [
            ...fakeTerminalOverrides(database: db),
            clockProvider.overrideWithValue(FixedClock(testTime)),
          ],
        );
        addTearDown(container.dispose);
      });

      AgentStatusReport sessionEnd(String conversationId, String reason) =>
          applyAgentHookCallback(
            container,
            agentId: AgentIds.claudeCode,
            event: 'SessionEnd',
            body: jsonEncode({
              'session_id': conversationId,
              'cwd': r'C:\src\demo',
              'hook_event_name': 'SessionEnd',
              'reason': reason,
            }),
          );

      test('a /clear or /resume leaves the row running', () {
        for (final reason in ['clear', 'resume']) {
          live('s-$reason');
          final report = sessionEnd('cli-s-$reason', reason);
          // Still an ending to the rebind and to automations.
          expect(report.ending, isNotNull, reason: reason);
          expect(statusOf('s-$reason'), SessionStatus.running, reason: reason);
        }
      });

      test('quitting the CLI still finishes the row', () {
        for (final reason in ['prompt_input_exit', 'logout', 'other']) {
          live('s-$reason');
          sessionEnd('cli-s-$reason', reason);
          expect(
            statusOf('s-$reason'),
            SessionStatus.completed,
            reason: reason,
          );
        }
      });
    });
  });

  group('the word a live-looking row is drawn with', () {
    test('a pane of ours we can see keeps the plain word', () {
      expect(SessionStatus.running.labelWhen(hostedLive: true), 'running');
    });

    test('a live claim with nothing behind it admits what it is', () {
      // A session launched into somebody else's terminal keeps `running` for
      // ever: no pane of ours ever stops, so the reconciler never hears about
      // it. `running` there is the confident false statement §19 deletes.
      expect(
        SessionStatus.running.labelWhen(hostedLive: false),
        'no ending was reported',
      );
      expect(
        SessionStatus.idle.labelWhen(hostedLive: false),
        'no ending was reported',
      );
    });

    test('a row that ended says how, whatever the panes are doing', () {
      for (final status in [
        SessionStatus.completed,
        SessionStatus.failed,
        SessionStatus.cancelled,
        SessionStatus.unknown,
      ]) {
        expect(
          status.labelWhen(hostedLive: false),
          status.name,
          reason: status.name,
        );
      }
    });
  });
}
