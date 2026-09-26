import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/application/session_plan_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/agent_plan_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A clock the test moves by hand, so an age is the test's own arithmetic.
class _FixedClock implements Clock {
  _FixedClock(this.now);

  DateTime now;

  @override
  DateTime nowUtc() => now;
}

/// **What the panel says**, in each of the states that matter.
///
/// The one it exists to get right is the difference between *no plan* and *a
/// plan we have not read*: an empty list drawn beside a running agent reads as
/// "no work planned", and every absence below is worded so it cannot.
void main() {
  final wroteAt = DateTime.utc(2026, 9, 8, 10);

  AgentPlan planOf(List<(String, String)> items) =>
      kClaudeCodeTodoWrite.planIn({
        'todos': [
          for (final (content, status) in items)
            {'content': content, 'status': status},
        ],
      })!;

  Future<void> pump(
    WidgetTester tester, {
    required AgentPlanReading reading,
    DateTime? now,
    bool polling = false,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          planPanelSessionIdProvider.overrideWithValue('s1'),
          sessionAgentPlanProvider.overrideWith((ref, id) => reading),
          chatTranscriptPollingProvider.overrideWithValue(polling),
          clockProvider.overrideWithValue(
            _FixedClock(now ?? wroteAt.add(const Duration(minutes: 2))),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: AgentPlanPanel()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('a plan on screen', () {
    testWidgets('draws every item in the agent\'s own words', (tester) async {
      await pump(
        tester,
        reading: AgentPlanReading.of(
          planOf([
            ('Audit the template systems', 'completed'),
            ('Wire the localisation keys', 'in_progress'),
            ('Document the font handling', 'pending'),
          ]),
          writtenAt: wroteAt,
        ),
      );
      expect(find.text('Audit the template systems'), findsOneWidget);
      expect(find.text('Wire the localisation keys'), findsOneWidget);
      expect(find.text('Document the font handling'), findsOneWidget);
      expect(find.text('1 of 3 done'), findsOneWidget);
    });

    testWidgets('says how old the reading is, always', (tester) async {
      await pump(
        tester,
        reading: AgentPlanReading.of(
          planOf([('One', 'in_progress')]),
          writtenAt: wroteAt,
        ),
        now: wroteAt.add(const Duration(minutes: 20)),
      );
      expect(find.text('Written 20m ago'), findsOneWidget);
    });

    testWidgets('an unknown write time is said, not rounded to now', (
      tester,
    ) async {
      // §19: an unknown reading time is not a reading time. A transcript line
      // with no timestamp must not borrow "just now".
      await pump(
        tester,
        reading: AgentPlanReading.of(
          planOf([('One', 'pending')]),
          writtenAt: null,
        ),
      );
      expect(find.text('Written at an unknown time'), findsOneWidget);
      expect(find.textContaining('ago'), findsNothing);
    });

    testWidgets('Codex\'s own sentence about the plan is shown', (
      tester,
    ) async {
      final plan = kCodexUpdatePlan.planIn(
        '{"explanation":"Calibrate the defaults first.",'
        '"plan":[{"step":"Inspect","status":"pending"}]}',
      )!;
      await pump(
        tester,
        reading: AgentPlanReading.of(plan, writtenAt: wroteAt),
      );
      expect(find.text('Calibrate the defaults first.'), findsOneWidget);
    });
  });

  group('finished, working and stalled are three different things', () {
    testWidgets('a finished list says so and is never marked stalled', (
      tester,
    ) async {
      await pump(
        tester,
        reading: AgentPlanReading.of(
          planOf([('One', 'completed'), ('Two', 'completed')]),
          writtenAt: wroteAt,
        ),
        now: wroteAt.add(const Duration(days: 2)),
      );
      expect(find.text('All 2 done'), findsOneWidget);
      expect(find.textContaining('Unchanged for over'), findsNothing);
    });

    testWidgets('work left and no movement is pointed at, not diagnosed', (
      tester,
    ) async {
      await pump(
        tester,
        reading: AgentPlanReading.of(
          planOf([('One', 'in_progress'), ('Two', 'pending')]),
          writtenAt: wroteAt,
        ),
        now: wroteAt.add(const Duration(minutes: 40)),
      );
      expect(find.text('Unchanged for over 15 minutes'), findsOneWidget);
      // Never "stuck": that is a diagnosis this app has no evidence for.
      expect(find.textContaining('stuck'), findsNothing);
    });

    testWidgets('a fresh plan with work left is neither', (tester) async {
      await pump(
        tester,
        reading: AgentPlanReading.of(
          planOf([('One', 'in_progress')]),
          writtenAt: wroteAt,
        ),
        now: wroteAt.add(const Duration(minutes: 3)),
      );
      expect(find.text('0 of 1 done'), findsOneWidget);
      expect(find.textContaining('Unchanged'), findsNothing);
    });
  });

  group('the four ways there is nothing to draw are four sentences', () {
    testWidgets('an agent that keeps none says so, in its own words', (
      tester,
    ) async {
      await pump(
        tester,
        reading: const AgentPlanReading.absent(
          AgentPlanAbsence.agentPublishesNone,
          refusal: 'Antigravity keeps no plan we can read.',
        ),
      );
      expect(
        find.textContaining('does not publish a plan'),
        findsOneWidget,
        reason: 'an empty list here would read as "no work planned"',
      );
      expect(
        find.textContaining('Antigravity keeps no plan we can read.'),
        findsOneWidget,
      );
    });

    testWidgets('an agent that has not written one yet is a different line', (
      tester,
    ) async {
      await pump(
        tester,
        reading: const AgentPlanReading.absent(AgentPlanAbsence.noneYet),
      );
      expect(find.textContaining('has not written a plan'), findsOneWidget);
      expect(find.textContaining('does not publish'), findsNothing);
    });

    testWidgets('a record we cannot read says that instead', (tester) async {
      await pump(
        tester,
        reading: const AgentPlanReading.absent(AgentPlanAbsence.noRecord),
      );
      expect(find.textContaining('No record of this session'), findsOneWidget);
    });

    testWidgets('unread behind the terminal says why, and what to do', (
      tester,
    ) async {
      // §19's remedy rule. Nothing here polls, so this state is real and the
      // honest thing is to name the gap rather than draw an empty list.
      await pump(
        tester,
        reading: const AgentPlanReading.absent(AgentPlanAbsence.notRead),
      );
      expect(find.textContaining('Not read yet'), findsOneWidget);
      expect(find.textContaining('chat view'), findsOneWidget);
    });

    testWidgets('unread while a conversation is up is merely loading', (
      tester,
    ) async {
      await pump(
        tester,
        reading: const AgentPlanReading.absent(AgentPlanAbsence.notRead),
        polling: true,
      );
      expect(find.textContaining('Reading'), findsOneWidget);
      expect(find.textContaining('Not read yet'), findsNothing);
    });
  });

  testWidgets('nothing selected asks for a session, not an empty list', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          planPanelSessionIdProvider.overrideWithValue(null),
          clockProvider.overrideWithValue(_FixedClock(wroteAt)),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: AgentPlanPanel()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Open a session'), findsOneWidget);
  });
}
