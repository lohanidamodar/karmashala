import 'package:agent_cli/stream.dart' show ToolActivity;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/explorer/application/explorer_actions.dart';
import 'package:karmashala/src/features/sessions/application/session_subagents_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';
import 'package:karmashala/src/features/sessions/presentation/delegation_card.dart';
import 'package:karmashala_core/util.dart' show Clock;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

/// Several children started together fold into one card in the parent's
/// chat, hung under the turn's words rather than inside its folded tool run.
void main() {
  final t0 = DateTime.utc(2026, 10, 4, 9);

  ChatMessage call(String name, String title, {String? child}) => ChatMessage(
    role: 'tool',
    text: name,
    tool: ToolActivity(
      name: name,
      subject: title,
      output: child == null
          ? null
          : '{"state":"started","childSessionId":"$child","mode":"async"}',
    ),
  );

  group('delegationGroups', () {
    test('two or more launches in one turn are one group, hung under the '
        "turn's next words", () {
      final groups = delegationGroups([
        const ChatMessage(role: 'user', text: 'Split it up'),
        call('mcp__karmashala__subagent_run', 'Audit the cart', child: 'c1'),
        call('Read', 'cart.dart'),
        call('mcp__karmashala__open_new_session', 'Write docs', child: 'c2'),
        const ChatMessage(role: 'agent', text: 'Started two helpers.'),
        const ChatMessage(role: 'user', text: 'thanks'),
      ]);
      expect(groups.keys, [4]);
      expect(groups[4]!.map((c) => (c.childId, c.title)), [
        ('c1', 'Audit the cart'),
        ('c2', 'Write docs'),
      ]);
    });

    test('a single launch is no group, and turns are not merged', () {
      final groups = delegationGroups([
        const ChatMessage(role: 'user', text: 'one'),
        call('mcp__karmashala__subagent_run', 'A', child: 'c1'),
        const ChatMessage(role: 'user', text: 'two'),
        call('mcp__karmashala__subagent_run', 'B', child: 'c2'),
      ]);
      expect(groups, isEmpty);
    });

    test('with no words after the calls yet, it hangs under the words '
        'before them; a call not yet answered has no child yet', () {
      final groups = delegationGroups([
        const ChatMessage(role: 'user', text: 'go'),
        call('karmashala.subagent_run', 'A', child: 'c1'),
        call('subagent_run', 'B'),
      ]);
      expect(groups.keys, [0]);
      expect(groups[0]!.map((c) => c.childId), ['c1', null]);
    });
  });

  group('DelegationGroupCard', () {
    final list = SessionSubagentList(
      sessionId: 'p',
      entries: [
        SessionSubagent(
          kind: SubagentKind.childSession,
          id: 'c1',
          title: 'Subagent: Audit the cart',
          state: SubagentState.done,
          agent: 'Codex',
          model: 'gpt-5',
          startedAt: t0,
          endedAt: t0.add(const Duration(minutes: 1, seconds: 5)),
          finalResult: 'Cart is fine.',
          childSessionId: 'c1',
        ),
        SessionSubagent(
          kind: SubagentKind.childSession,
          id: 'c2',
          title: 'Write docs',
          state: SubagentState.running,
          agent: 'Claude Code',
          startedAt: t0,
          childSessionId: 'c2',
        ),
      ],
    );

    Future<void> pump(WidgetTester tester, Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sessionSubagentsProvider.overrideWith(
              (ref, _) => Stream.value(list),
            ),
            clockProvider.overrideWithValue(
              _FixedClock(t0.add(const Duration(minutes: 3))),
            ),
            explorerActionsProvider.overrideWith(_Actions.new),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: DelegationGroupCard(
                parentSessionId: 'p',
                calls: [
                  DelegationCall(childId: 'c1', title: 'Audit the cart'),
                  DelegationCall(childId: 'c2', title: 'Write docs'),
                  DelegationCall(title: 'Starting'),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    for (final size in const [Size(390, 844), Size(1440, 900)]) {
      testWidgets('folded, it counts the children and how far they got, at '
          '${size.width.toInt()} wide', (tester) async {
        await pump(tester, size);
        expect(find.text('Delegated 3 sessions'), findsOneWidget);
        expect(find.textContaining('1 running'), findsOneWidget);
        expect(find.textContaining('1 done'), findsOneWidget);
        expect(find.text('Cart is fine.'), findsNothing);

        await tester.tap(find.text('Delegated 3 sessions'));
        await tester.pumpAndSettle();
        expect(find.text('Audit the cart'), findsOneWidget);
        expect(find.text('Codex · gpt-5 · Done · 1m 05s'), findsOneWidget);
        expect(find.text('Cart is fine.'), findsOneWidget);
        expect(find.text('Claude Code · Running · 3m 00s'), findsOneWidget);
        expect(find.text('Starting'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('a child opens its own session', (tester) async {
      await pump(tester, const Size(1440, 900));
      await tester.tap(find.text('Delegated 3 sessions'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('delegation-child-c2')));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(DelegationGroupCard)),
      );
      expect((container.read(explorerActionsProvider) as _Actions).opened, [
        'c2',
      ]);
    });
  });
}

class _Actions extends ExplorerActions {
  _Actions(super.ref);

  final opened = <String>[];

  @override
  Future<ExplorerResult> openNative(String sessionId) async {
    opened.add(sessionId);
    return const ExplorerResult(ExplorerOutcome.started);
  }
}

class _FixedClock implements Clock {
  const _FixedClock(this.now);

  final DateTime now;

  @override
  DateTime nowUtc() => now;
}
