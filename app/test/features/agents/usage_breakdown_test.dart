import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/application/usage_session_tokens.dart';
import 'package:karmashala/src/features/agents/presentation/usage_tab/usage_breakdown_section.dart';
import 'package:karmashala_ui/theme.dart';

/// The Usage tab's thinking split: how much of the range's output was
/// reasoning, over the sessions whose files break it out. A session that does
/// not break it out is left out of the share rather than counted as none.
void main() {
  final since = DateTime.utc(2026, 9, 1);
  final inRange = DateTime.utc(2026, 9, 10);

  UsageSessionRow row(
    String id, {
    int? tokens = 1000,
    int? output,
    int? reasoning,
    DateTime? last,
  }) => UsageSessionRow(
    sessionId: id,
    title: id,
    project: 'p',
    agentId: 'claude-code',
    tokens: tokens,
    output: output,
    reasoning: reasoning,
    lastActivityAt: last ?? inRange,
  );

  group('usageBreakdownOf', () {
    test('adds thinking up over the sessions that record it', () {
      final breakdown = usageBreakdownOf([
        row('a', output: 100, reasoning: 30),
        row('b', output: 50, reasoning: 20),
        // Recorded output, but never broke thinking out: not in the share.
        row('c', output: 900),
        // Out of range: not in anything.
        row('d', output: 10, reasoning: 10, last: DateTime.utc(2026, 8, 1)),
      ], since: since);

      expect(breakdown.thinking, (output: 150, reasoning: 50, sessions: 2));
    });

    test('is not recorded when no session breaks thinking out', () {
      final breakdown = usageBreakdownOf([
        row('a', output: 100),
        row('b'),
      ], since: since);

      expect(breakdown.thinking, isNull);
    });
  });

  group('UsageWhereItWent', () {
    Future<void> pump(WidgetTester tester, UsageBreakdown breakdown) =>
        tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: SingleChildScrollView(
                child: UsageWhereItWent(breakdown: breakdown),
              ),
            ),
          ),
        );

    Finder text(String pattern) =>
        find.textContaining(pattern, findRichText: true);

    testWidgets('says how the output divided and over how many sessions', (
      tester,
    ) async {
      await pump(
        tester,
        usageBreakdownOf([
          row('a', output: 100, reasoning: 30),
          row('b', output: 50, reasoning: 20),
          row('c', output: 900),
        ], since: since),
      );

      expect(find.text('THINKING'), findsOneWidget);
      expect(text('Answer  100  67%'), findsOneWidget);
      expect(text('Thinking  50  33%'), findsOneWidget);
      expect(
        text('2 of 3 sessions break thinking out of their output.'),
        findsOneWidget,
      );
    });

    testWidgets('says so when no session records it', (tester) async {
      await pump(
        tester,
        usageBreakdownOf([row('a', output: 100)], since: since),
      );

      expect(find.text('THINKING'), findsOneWidget);
      expect(
        text('Not recorded — no session in the range breaks thinking out'),
        findsOneWidget,
      );
    });
  });
}
