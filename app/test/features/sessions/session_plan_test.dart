import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/application/session_plan_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/launch.dart';
import 'package:agent_cli/stream.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

/// **Which plan is the plan, how old it is, and the four ways there is none.**
///
/// The failure this file exists to stop is a stale list that looks current. A
/// plan the agent overtook forty minutes ago renders exactly like one it wrote
/// a second ago, and a reader glancing at four panes has nothing to tell them
/// apart — so every reading carries the instant the agent wrote it (§19), and
/// an empty answer says *which* nothing it is.
void main() {
  final wroteAt = DateTime.utc(2026, 9, 8, 10);

  TranscriptMessage planRow(
    List<(String, String)> items, {
    DateTime? at,
    String tool = 'TodoWrite',
  }) {
    final plan = kClaudeCodeTodoWrite.planIn({
      'todos': [
        for (final (content, status) in items)
          {'content': content, 'status': status},
      ],
    });
    return TranscriptMessage(
      role: 'tool',
      text: tool,
      tool: ToolActivity(name: tool, subject: plan?.headline, plan: plan),
      at: at ?? wroteAt,
    );
  }

  TranscriptMessage chatter(String text) =>
      TranscriptMessage(role: 'agent', text: text, at: wroteAt);

  group('the last snapshot is the plan', () {
    test('a later write replaces an earlier one entirely', () {
      final reading = agentPlanIn([
        planRow([
          ('One', 'in_progress'),
          ('Two', 'pending'),
          ('Three', 'pending'),
        ], at: wroteAt),
        chatter('working on it'),
        planRow([
          ('One', 'completed'),
        ], at: wroteAt.add(const Duration(minutes: 5))),
      ]);
      // Folding would have drawn three items; the agent dropped two.
      expect(reading.plan!.total, 1);
      expect(reading.plan!.doneCount, 1);
      expect(reading.plan!.isFinished, isTrue);
      expect(reading.writtenAt, wroteAt.add(const Duration(minutes: 5)));
    });

    test('a row we could not parse leaves the last plan we could', () {
      // The format-change case: the plan already on screen survives, with its
      // age, rather than being replaced by "no work planned".
      final unreadable = TranscriptMessage(
        role: 'tool',
        text: 'TodoWrite',
        tool: const ToolActivity(name: 'TodoWrite'),
        at: wroteAt.add(const Duration(minutes: 9)),
      );
      final reading = agentPlanIn([
        planRow([('One', 'in_progress')], at: wroteAt),
        unreadable,
      ]);
      expect(reading.plan!.items.single.text, 'One');
      expect(reading.writtenAt, wroteAt);
    });

    test('a transcript with no plan in it is noneYet, not an empty plan', () {
      final reading = agentPlanIn([chatter('hello'), chatter('goodbye')]);
      expect(reading.hasPlan, isFalse);
      expect(reading.absence, AgentPlanAbsence.noneYet);
      expect(reading.plan, isNull);
    });

    test('two reads of the same plan are the same value', () {
      // The transcript is re-parsed whenever the file moves; a re-parse that
      // found the same plan must leave the panel asleep.
      final a = agentPlanIn([
        planRow([('One', 'pending')]),
      ]);
      final b = agentPlanIn([
        planRow([('One', 'pending')]),
      ]);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });

  group('every reading carries its age', () {
    test('the age is the agent\'s own timestamp, not a sighting', () {
      final reading = agentPlanIn([
        planRow([('One', 'in_progress')]),
      ]);
      expect(
        reading.ageAt(wroteAt.add(const Duration(minutes: 20))),
        const Duration(minutes: 20),
      );
    });

    test('a line with no timestamp has no age, and says so', () {
      final reading = agentPlanIn([
        TranscriptMessage(
          role: 'tool',
          text: 'TodoWrite',
          tool: ToolActivity(
            name: 'TodoWrite',
            plan: kClaudeCodeTodoWrite.planIn({
              'todos': [
                {'content': 'One', 'status': 'pending'},
              ],
            }),
          ),
        ),
      ]);
      expect(reading.hasPlan, isTrue);
      expect(reading.writtenAt, isNull);
      // Never zero: an unknown age is not an age of nothing.
      expect(reading.ageAt(wroteAt), isNull);
      expect(reading.isStaleAt(wroteAt), isFalse);
    });

    test('a clock that runs ahead of ours is not a plan from the future', () {
      final reading = agentPlanIn([
        planRow([('One', 'pending')]),
      ]);
      expect(
        reading.ageAt(wroteAt.subtract(const Duration(hours: 1))),
        Duration.zero,
      );
    });
  });

  group('a finished list looks different from an abandoned one', () {
    test('work left and fifteen minutes of silence reads as stalled', () {
      final reading = agentPlanIn([
        planRow([('One', 'in_progress'), ('Two', 'pending')]),
      ]);
      expect(
        reading.isStaleAt(wroteAt.add(const Duration(minutes: 14))),
        isFalse,
      );
      expect(reading.isStaleAt(wroteAt.add(kPlanGoesStaleAfter)), isTrue);
    });

    test('a finished list is never stalled, however old it is', () {
      final reading = agentPlanIn([
        planRow([('One', 'completed')]),
      ]);
      expect(reading.plan!.isFinished, isTrue);
      expect(reading.isStaleAt(wroteAt.add(const Duration(days: 3))), isFalse);
    });

    test(
      'an item in a word we do not know is not done and not stale-proof',
      () {
        final reading = agentPlanIn([
          planRow([('One', 'blocked')]),
        ]);
        expect(reading.plan!.items.single.state, AgentPlanItemState.unrecorded);
        expect(reading.plan!.isFinished, isFalse);
        expect(reading.isStaleAt(wroteAt.add(kPlanGoesStaleAfter)), isTrue);
      },
    );
  });

  group('the provider, and the four ways there is no plan', () {
    ProviderContainer containerFor({
      required List<TranscriptMessage> messages,
      String agentId = AgentIds.claudeCode,
      SessionSurface surface = SessionSurface.pane,
      String? externalSessionId = 'ext-1',
      void Function()? onTranscriptSubscribed,
    }) {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      ExecutionEnvironmentDao(db).upsert(windowsEnv());
      ProjectDao(db).insert(project());
      RepositoryDao(db).insert(repository());
      AgentInstallationDao(db).insert(agentInstallation(agentId: agentId));
      SessionDao(db).insert(
        Session(
          id: 's1',
          repositoryId: 'r1',
          agentInstallationId: 'a1',
          title: 'Session',
          useWorktree: false,
          status: SessionStatus.running,
          createdAt: testTime,
          surface: surface,
          externalSessionId: externalSessionId,
        ),
      );
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          sessionChatTranscriptProvider.overrideWith((ref, id) {
            onTranscriptSubscribed?.call();
            return Stream.value(messages);
          }),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    /// [readsTranscript] says whether this case is expected to reach the
    /// transcript at all. When it is not, nothing here may touch that provider
    /// — creating it to await it is what made the "costs nothing" assertion
    /// below measure the test instead of the code.
    Future<AgentPlanReading> readingFor({
      required List<TranscriptMessage> messages,
      String agentId = AgentIds.claudeCode,
      SessionSurface surface = SessionSurface.pane,
      String? externalSessionId = 'ext-1',
      bool readsTranscript = true,
      void Function()? onTranscriptSubscribed,
    }) async {
      final container = containerFor(
        messages: messages,
        agentId: agentId,
        surface: surface,
        externalSessionId: externalSessionId,
        onTranscriptSubscribed: onTranscriptSubscribed,
      );
      final subscription = container.listen(
        sessionAgentPlanProvider('s1'),
        (_, _) {},
      );
      if (!readsTranscript) {
        final reading = subscription.read();
        subscription.close();
        return reading;
      }
      // Held open by the test: awaiting an `autoDispose` stream nobody listens
      // to disposes it mid-flight.
      final source = container.listen(
        sessionChatTranscriptProvider('s1'),
        (_, _) {},
      );
      await container.read(sessionChatTranscriptProvider('s1').future);
      final reading = subscription.read();
      source.close();
      subscription.close();
      return reading;
    }

    test('a Claude Code session reads its own list', () async {
      final reading = await readingFor(
        messages: [
          planRow([('One', 'in_progress'), ('Two', 'pending')]),
        ],
      );
      expect(reading.plan!.total, 2);
      expect(reading.writtenAt, wroteAt);
    });

    test('a Codex session reads its own, off its own vocabulary', () async {
      final plan = kCodexUpdatePlan.planIn(
        '{"plan":[{"step":"Inspect","status":"completed"},'
        '{"step":"Measure","status":"in_progress"}]}',
      );
      final reading = await readingFor(
        agentId: AgentIds.codex,
        messages: [
          TranscriptMessage(
            role: 'tool',
            text: 'update_plan',
            tool: ToolActivity(name: 'update_plan', plan: plan),
            at: wroteAt,
          ),
        ],
      );
      expect(reading.plan!.doneCount, 1);
      expect(reading.plan!.current?.text, 'Measure');
    });

    test('Antigravity says it publishes none, and reads nothing', () async {
      var subscribed = 0;
      final reading = await readingFor(
        agentId: AgentIds.antigravity,
        messages: [
          planRow([('One', 'pending')]),
        ],
        readsTranscript: false,
        onTranscriptSubscribed: () => subscribed++,
      );
      expect(reading.absence, AgentPlanAbsence.agentPublishesNone);
      expect(reading.refusal, isNotEmpty);
      expect(
        subscribed,
        0,
        reason:
            'the capability answer is free — an agent that keeps no plan must '
            'not reach a transcript subscription to find that out',
      );
    });

    test('no CLI session id yet reads as noRecord', () async {
      final reading = await readingFor(
        messages: [
          planRow([('One', 'pending')]),
        ],
        externalSessionId: null,
        readsTranscript: false,
      );
      expect(reading.absence, AgentPlanAbsence.noRecord);
    });

    test('a session outside our panes reads as noRecord', () async {
      final reading = await readingFor(
        messages: [
          planRow([('One', 'pending')]),
        ],
        surface: SessionSurface.external,
        readsTranscript: false,
      );
      expect(reading.absence, AgentPlanAbsence.noRecord);
    });

    test('an empty transcript is notRead, never "no plan"', () async {
      // The chat source yields an empty list before it has found the file and
      // while the poll is paused behind the terminal. Neither is evidence that
      // the agent planned nothing.
      final reading = await readingFor(messages: const []);
      expect(reading.absence, AgentPlanAbsence.notRead);
    });

    test('turns but no plan is noneYet — a different sentence', () async {
      final reading = await readingFor(messages: [chatter('hello')]);
      expect(reading.absence, AgentPlanAbsence.noneYet);
    });

    test('a closed panel costs nothing at all', () async {
      // "An idle app costs zero", literally: `sessionAgentPlanProvider` is
      // `autoDispose`, so with the Plan surface shut nobody listens, the
      // provider is never created and the transcript is never subscribed. The
      // whole feature is behind one rail glyph nobody has clicked.
      var subscribed = 0;
      final container = containerFor(
        messages: [
          planRow([('One', 'pending')]),
        ],
        onTranscriptSubscribed: () => subscribed++,
      );
      // A full frame's worth of other work, with the panel closed.
      container.read(sessionDaoProvider).getById('s1');
      expect(subscribed, 0);
    });

    test('the panel adds no transcript subscription of its own', () async {
      // The whole cost argument: the conversation, the activity strip and this
      // share one `autoDispose` family entry, so one poll and one parse serve
      // all three.
      var subscribed = 0;
      await readingFor(
        messages: [
          planRow([('One', 'pending')]),
        ],
        onTranscriptSubscribed: () => subscribed++,
      );
      expect(subscribed, 1);
    });
  });

  group('the reasoning beside a plan is not part of it', () {
    // Antigravity's reader fills `TranscriptMessage.thinking`, and 425 of the
    // 435 blocks on this machine sit on the record that made a tool call — so
    // the field now arrives on exactly the rows this walk looks at. It reads
    // `tool.plan` and nothing else, and these say so rather than leaving it to
    // be rediscovered the next time a reader learns a new field.
    TranscriptMessage thinkingOn(TranscriptMessage row, String thinking) =>
        TranscriptMessage(
          role: row.role,
          text: row.text,
          tool: row.tool,
          at: row.at,
          thinking: thinking,
        );

    test('a plan row that also carries reasoning reads identically', () {
      final plain = planRow([('One', 'in_progress'), ('Two', 'pending')]);
      final withThinking = thinkingOn(plain, 'do Two first, maybe');

      final reading = agentPlanIn([withThinking]);

      expect(reading.plan, agentPlanIn([plain]).plan);
      expect(reading.writtenAt, wroteAt);
    });

    test('a row that carries only reasoning publishes no plan', () {
      // Antigravity publishes no plan tool at all — 4,451 steps, none — so its
      // rows reaching this walk must leave it saying there is nothing yet.
      final reading = agentPlanIn([
        thinkingOn(chatter('Looking into it.'), 'the failing test first'),
        TranscriptMessage(
          role: 'tool',
          text: 'run_command',
          tool: const ToolActivity(name: 'run_command', subject: 'ls -1'),
          at: wroteAt,
          thinking: 'and then the diff',
        ),
      ]);

      expect(reading.plan, isNull);
      expect(reading.absence, AgentPlanAbsence.noneYet);
    });

    test('reasoning on a later row does not overtake the plan', () {
      final reading = agentPlanIn([
        planRow([('One', 'completed')]),
        thinkingOn(chatter('Nearly there.'), 'nothing left to plan'),
      ]);

      expect(reading.plan?.items.single.text, 'One');
      expect(reading.writtenAt, wroteAt);
    });
  });
}
