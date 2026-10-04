import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart' show TranscriptMessage;
import 'package:agent_cli/stream.dart' show ToolActivity;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/domain/plan_changes.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_cards/plan_update_card.dart';

import '../../support/fixtures.dart';
import 'chat_cards_support.dart';

const _pending = AgentPlanItemState.pending;
const _doing = AgentPlanItemState.inProgress;
const _done = AgentPlanItemState.completed;

void main() {
  group('planChanges', () {
    test('a first plan has no changes: it is drawn whole', () {
      expect(planChanges(null, planOf({'A': _pending})), isEmpty);
    });

    test('names what was finished, started, added and dropped', () {
      final before = planOf({'A': _doing, 'B': _pending, 'C': _pending});
      final after = planOf({'A': _done, 'B': _doing, 'D': _pending});
      expect(planChanges(before, after), [
        const PlanChange(PlanChangeKind.completed, 'A'),
        const PlanChange(PlanChangeKind.started, 'B'),
        const PlanChange(PlanChangeKind.added, 'D'),
        const PlanChange(PlanChangeKind.dropped, 'C'),
      ]);
    });

    test('an identical resend changes nothing', () {
      final plan = planOf({'A': _doing});
      expect(planChanges(plan, plan), isEmpty);
    });
  });

  for (final kind in ChatCardSession.values) {
    group('${kind.name}:', () {
      final first = planOf({'Read the code': _doing, 'Fix it': _pending});
      final second = planOf({'Read the code': _done, 'Fix it': _doing});

      List<TranscriptMessage> turn() => [
        TranscriptMessage(role: 'user', text: 'Fix the bug.', at: testTime),
        planRow(kind, first),
        TranscriptMessage(
          role: 'tool',
          text: '',
          tool: const ToolActivity(name: 'Read', subject: 'lib/main.dart'),
          at: testTime.add(const Duration(seconds: 2)),
        ),
        TranscriptMessage(
          role: 'tool',
          text: '',
          tool: const ToolActivity(name: 'Bash', subject: 'ls', output: 'a'),
          at: testTime.add(const Duration(seconds: 3)),
        ),
        planRow(kind, second, at: testTime.add(const Duration(seconds: 4))),
      ];

      testWidgets('the plan is a checklist where it was written, its update '
          'a list of what changed', (tester) async {
        final h = await ChatCardHarness.open(kind, messages: turn());
        addTearDown(h.dispose);
        await h.pump(tester);

        final cards = find.byType(PlanUpdateCard);
        // Never folded into the turn's "Worked for…" line.
        expect(cards, findsNWidgets(2));
        // The first: the whole list, in the agent's words.
        final firstCard = cards.first;
        for (final item in ['Read the code', 'Fix it']) {
          expect(
            find.descendant(of: firstCard, matching: find.text(item)),
            findsOneWidget,
          );
        }
        // The update: only what moved.
        final update = cards.last;
        expect(
          find.descendant(
            of: update,
            matching: find.textContaining('Completed'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: update, matching: find.textContaining('Started')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: update, matching: find.text('1 of 2 done')),
          findsOneWidget,
        );
        // The whole list is one tap away on the update.
        await tester.tap(
          find.descendant(of: update, matching: find.text('Show plan')),
        );
        await tester.pumpAndSettle();
        expect(
          find.descendant(of: update, matching: find.text('Fix it')),
          findsWidgets,
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets('the latest plan is pinned above the composer while a turn '
          'runs, and only then', (tester) async {
        final h = await ChatCardHarness.open(
          kind,
          messages: turn(),
          status: ChatCardHarness.statusOf(kind, AgentActivityStatus.working),
        );
        addTearDown(h.dispose);
        await h.pump(tester);

        final pinned = find.byKey(const ValueKey('pinned-plan'));
        expect(pinned, findsOneWidget);
        expect(
          find.descendant(of: pinned, matching: find.textContaining('Fix it')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: pinned, matching: find.textContaining('1/2')),
          findsOneWidget,
        );

        h.status(ChatCardHarness.idle(kind));
        await tester.pumpAndSettle();
        expect(pinned, findsNothing);
      });
    });
  }
}
