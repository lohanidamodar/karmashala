import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/reveal_session.dart';
import 'package:karmashala/src/features/agents/application/usage_session_tokens.dart';
import 'package:karmashala/src/features/agents/presentation/usage_tab/usage_cost_section.dart';
import 'package:karmashala/src/features/agents/presentation/usage_tab/usage_tab_state.dart';
import 'package:karmashala_ui/theme.dart';

import '../../support/fake_data_server.dart';

/// Cost on the Usage tab (round 84): only what agents reported — by project
/// and for today's most expensive sessions — and "not recorded" otherwise,
/// never a zero or a figure worked out from tokens.
void main() {
  final now = DateTime.utc(2026, 10, 9, 12);
  final earlier = now.subtract(const Duration(hours: 1));

  UsageSessionRow row(
    String id, {
    String project = 'karmashala',
    int? tokens,
    double? cost,
    String? currency = 'USD',
    DateTime? last,
  }) => UsageSessionRow(
    sessionId: id,
    title: 'Session $id',
    project: project,
    agentId: 'opencode',
    tokens: tokens,
    costAmount: cost,
    costCurrency: cost == null ? null : currency,
    lastActivityAt: last ?? earlier,
  );

  group('cost by project', () {
    test('sums reported amounts only, largest first', () {
      final costs = usageCostByProject([
        row('a', cost: 0.5),
        row('b', cost: 0.25),
        row('c', project: 'site', cost: 2),
        // Tokens alone are not a cost.
        row('d', tokens: 90000),
        // Out of the range.
        row('e', cost: 9, last: now.subtract(const Duration(days: 40))),
      ], since: now.subtract(const Duration(days: 7)));
      expect([for (final c in costs) c.project], ['site', 'karmashala']);
      expect(costs.last.amount, 0.75);
      expect(costs.last.sessions, 2);
    });

    test('two currencies are never summed', () {
      final costs = usageCostByProject([
        row('a', cost: 1),
        row('b', cost: 1, currency: 'EUR'),
      ], since: now.subtract(const Duration(days: 1)));
      expect(costs, hasLength(2));
    });
  });

  group('most expensive today', () {
    test('reported cost first, then tokens; nothing recorded is left out', () {
      final top = usageMostExpensive([
        row('tokens-only', tokens: 5000000),
        row('cheap', cost: 0.1),
        row('dear', cost: 3),
        row('nothing'),
        row('yesterday', cost: 50, last: now.subtract(const Duration(days: 1))),
      ], since: now.subtract(const Duration(hours: 12)));
      expect(
        [for (final r in top) r.sessionId],
        ['dear', 'cheap', 'tokens-only'],
      );
    });

    test('at most five', () {
      final top = usageMostExpensive([
        for (var i = 0; i < 9; i++) row('$i', cost: i.toDouble()),
      ], since: now.subtract(const Duration(hours: 12)));
      expect(top, hasLength(5));
    });

    test('a row says "cost not recorded" rather than a guess', () {
      expect(
        usageCostLine(row('t', tokens: 1200)),
        contains('cost not recorded'),
      );
      expect(usageCostLine(row('c', cost: 0.42)), startsWith('\$0.42'));
    });
  });

  Future<ProviderContainer> pump(
    WidgetTester tester,
    List<UsageSessionRow> rows,
  ) async {
    final container = ProviderContainer(
      overrides: [await FakeDataServer().override()],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: UsageCostSection(
                rows: rows,
                range: UsageRange.week,
                now: now,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('with nothing reported, the section says "not recorded"', (
    tester,
  ) async {
    await pump(tester, [row('a', tokens: 1000)]);
    expect(
      find.byKey(const ValueKey('usage-cost-not-recorded')),
      findsOneWidget,
    );
    expect(find.textContaining('\$0.00'), findsNothing);
    expect(find.textContaining('cost not recorded'), findsOneWidget);
  });

  testWidgets('reported cost is drawn, and a row opens the peek', (
    tester,
  ) async {
    final c = await pump(tester, [row('gone', cost: 1.2)]);
    expect(find.text('\$1.20'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('usage-cost-row-gone')));
    await tester.pumpAndSettle();
    // A session that is no longer here says so, as any reveal does.
    expect(
      c.read(sessionRevealNoticeProvider)?.message,
      contains('no longer here'),
    );
    // Opening the dashboard starts the terminals' autosave; end it here.
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}
