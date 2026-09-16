import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/application/session_token_totals.dart';
import 'package:karmashala/src/features/settings/presentation/usage_tokens_card.dart';
import 'package:karmashala_ui/charts.dart';

import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';

/// Tokens by project and by agent: which sessions count, how they group, and
/// the card that shows it only when asked.
void main() {
  final since = testTime.subtract(kTokenTotalsPeriod);
  final recent = testTime.subtract(const Duration(days: 1));

  SessionTokens row(
    String project,
    String agent,
    int? tokens, {
    DateTime? last,
    bool unknownLast = false,
  }) => (
    project: project,
    agent: agent,
    tokens: tokens,
    lastActivityAt: unknownLast ? null : (last ?? recent),
  );

  group('aggregateTokenTotals', () {
    test('groups by project and by agent, largest first', () {
      final totals = aggregateTokenTotals([
        row('karmashala', 'Claude Code', 1200),
        row('karmashala', 'Codex CLI', 300),
        row('aakar', 'Claude Code', 2000),
      ], since: since);
      expect(totals.byProject, [('aakar', 2000), ('karmashala', 1500)]);
      expect(totals.byAgent, [('Claude Code', 3200), ('Codex CLI', 300)]);
      expect(totals.total, 3500);
      expect(totals.counted, 3);
      expect(totals.uncounted, 0);
    });

    test('a session last active before the period is left out', () {
      final totals = aggregateTokenTotals([
        row('old', 'Codex CLI', 9000, last: since.subtract(const Duration(minutes: 1))),
        row('new', 'Codex CLI', 10, last: since),
      ], since: since);
      expect(totals.byProject, [('new', 10)]);
    });

    test('a session with no counts is uncounted, never zero', () {
      final totals = aggregateTokenTotals([
        row('p', 'Antigravity', null),
        row('p', 'Claude Code', null, unknownLast: true),
        row('p', 'Claude Code', 5),
      ], since: since);
      expect(totals.byAgent, [('Claude Code', 5)]);
      expect(totals.uncounted, 2);
      expect(totals.counted, 1);
    });

    test('tokens with an unknown last activity are not placed in the period',
        () {
      final totals = aggregateTokenTotals([
        row('p', 'Claude Code', 50, unknownLast: true),
      ], since: since);
      expect(totals.isEmpty, isTrue);
    });
  });

  test('formatTokenCount is label-sized', () {
    expect(formatTokenCount(812), '812');
    expect(formatTokenCount(1500), '1.5k');
    expect(formatTokenCount(34000), '34k');
    expect(formatTokenCount(1250000), '1.3M');
    expect(formatTokenCount(42000000), '42M');
  });

  group('the card', () {
    final totals = aggregateTokenTotals([
      row('karmashala-app with a long project name', 'Claude Code', 1250000),
      row('aakar', 'Codex CLI', 34000),
      row('aakar', 'Antigravity', null),
    ], since: since);

    Widget card({Future<TokenTotals> Function()? answer}) => ProviderScope(
      overrides: [
        tokenTotalsProvider.overrideWith(
          (ref) => answer == null ? Future.value(totals) : answer(),
        ),
      ],
      child: const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: SingleChildScrollView(child: UsageTokensCard()),
        ),
      ),
    );

    testWidgets('counts nothing until asked', (tester) async {
      var asked = 0;
      await tester.pumpWidget(
        card(
          answer: () {
            asked++;
            return Future.value(totals);
          },
        ),
      );
      expect(asked, 0);
      expect(find.byType(RankedBars), findsNothing);

      await tester.tap(find.text('Count tokens'));
      await tester.pump();
      await tester.pump();
      expect(asked, 1);
      expect(find.text('1.3M tokens across 2 sessions'), findsOneWidget);
      expect(find.byType(RankedBars), findsNWidgets(2));
      expect(find.textContaining('1 recorded no counts'), findsOneWidget);
    });

    testWidgets('survives the window matrix with results on it', (
      tester,
    ) async {
      await expectSurvivesWindowMatrix(
        tester,
        build: card,
        warmUp: (tester) async {
          await tester.tap(find.text('Count tokens'));
          await tester.pump();
          await tester.pump();
        },
      );
    });
  });
}
