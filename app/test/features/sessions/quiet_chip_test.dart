import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/explorer/application/agent_states.dart';
import 'package:karmashala/src/features/overview/application/overview_board.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/quiet_chip.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// **"Quiet 15m"**: the server's mark on a working session, in the warning
/// colour, saying since when, with what to do a click away.
void main() {
  final since = testTime;
  final now = testTime.add(const Duration(minutes: 15));

  AgentStatusReport report({
    AgentActivityStatus status = AgentActivityStatus.working,
    DateTime? quietSince,
  }) => AgentStatusReport(
    agentId: AgentIds.claudeCode,
    sessionId: 's1',
    status: status,
    observedAt: now,
    source: AgentStatusSource.hook,
    detail: 'Running the test suite',
    quietSince: quietSince,
  );

  Widget host(
    AgentStatusReport status, {
    VoidCallback? onPeek,
    double width = 1440,
    double textScale = 1,
  }) => ProviderScope(
    overrides: [
      clockProvider.overrideWithValue(MovableClock(now)),
      agentSessionStatusProvider.overrideWith(
        (ref, id) => Stream.value(status),
      ),
      sessionStatusLookupProvider.overrideWithValue((_) => status),
    ],
    child: MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(width, 800),
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(
          body: SizedBox(
            width: width,
            // As the status line and a card header hold it: beside a title
            // that gives way; and as a sidebar row's narrow trailing column.
            child: Column(
              children: [
                Row(
                  children: [
                    const Expanded(child: Text('A long session title here')),
                    QuietChip(sessionId: 's1', onPeek: onPeek),
                  ],
                ),
                Row(
                  children: [
                    const Expanded(child: Text('A long session title here')),
                    SizedBox(
                      key: const ValueKey('narrow-column'),
                      width: Touch.target,
                      child: QuietChip(sessionId: 's1', compact: true),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets('nothing while not quiet, or not working', (tester) async {
    await tester.pumpWidget(host(report()));
    await tester.pumpAndSettle();
    expect(find.textContaining('Quiet'), findsNothing);

    await tester.pumpWidget(
      host(
        report(status: AgentActivityStatus.awaitingApproval, quietSince: since),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Quiet'), findsNothing);
  });

  testWidgets('says how long, in the warning colour, and since when', (
    tester,
  ) async {
    await tester.pumpWidget(host(report(quietSince: since)));
    await tester.pumpAndSettle();
    final label = find.text('Quiet 15m');
    expect(label, findsOneWidget);
    final attention = SemanticColors.of(tester.element(label)).attention;
    expect(tester.widget<Text>(label).style?.color, attention);
    final tip = tester.widget<Tooltip>(
      find.byKey(const ValueKey('session-quiet:s1')).first,
    );
    expect(tip.message, contains('Nothing new since'));
    expect(tip.message, contains('Last: Running the test suite'));
  });

  testWidgets('a click offers Peek, Nudge, Stop and End; Nudge asks first', (
    tester,
  ) async {
    var peeked = 0;
    await tester.pumpWidget(
      host(report(quietSince: since), onPeek: () => peeked++),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Quiet 15m'));
    await tester.pumpAndSettle();
    for (final item in [
      'Peek at the terminal',
      'Nudge…',
      'Stop',
      'End session…',
    ]) {
      expect(find.text(item), findsOneWidget, reason: item);
    }
    await tester.tap(find.text('Peek at the terminal'));
    await tester.pumpAndSettle();
    expect(peeked, 1);

    await tester.tap(find.text('Quiet 15m'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nudge…'));
    await tester.pumpAndSettle();
    expect(find.textContaining(kQuietNudgeText), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('with no peek on offer, the menu leaves it out', (tester) async {
    await tester.pumpWidget(host(report(quietSince: since)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Quiet 15m'));
    await tester.pumpAndSettle();
    expect(find.text('Peek at the terminal'), findsNothing);
    expect(find.text('Nudge…'), findsOneWidget);
  });

  for (final width in [360.0, 1440.0]) {
    testWidgets('fits at $width px and text x1.6', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 800);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        host(report(quietSince: since), width: width, textScale: 1.6),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('session-quiet:s1')), findsNWidgets(2));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('narrow-column')),
          matching: find.text('15m'),
        ),
        findsOneWidget,
      );
    });
  }

  group('the dashboard', () {
    test('a quiet counter singles quiet out of the working column', () {
      expect(OverviewCounter.quiet.column, BoardColumn.working);
      expect(OverviewCounter.quiet.state, AgentState.quiet);
      const filter = OverviewFilter(
        columns: {BoardColumn.working},
        states: {AgentState.quiet},
      );
      expect(OverviewCounter.quiet.selectedIn(filter), isTrue);
      expect(OverviewCounter.working.selectedIn(filter), isFalse);
    });
  });
}
