import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_session/lineage.dart';
import 'package:karmashala/src/features/verification/application/review_session_service.dart';
import 'package:karmashala/src/features/verification/presentation/review_action.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';
import '../fanout/fanout_harness.dart';

/// The control is pumped over the fan-out harness — a real `SessionLauncher`
/// over fake terminals — so pressing it starts a session the same way the app
/// does rather than through a friendlier stand-in.
void main() {
  late Harness h;

  setUp(() {
    h = harness();
    // The work under review: an ordinary row, run by the first installation.
    SessionDao(h.db).insert(
      session(
        id: 's-work',
        agentInstallationId: roverInstall.id,
        title: 'Fix the parser',
      ),
    );
  });
  tearDown(() {
    h.container.dispose();
    h.db.close();
  });

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    UncontrolledProviderScope(
      container: h.container,
      child: const MaterialApp(
        home: Scaffold(body: ReviewAction(sessionId: 's-work')),
      ),
    ),
  );

  testWidgets('one other installation is one press, and it names the agent', (
    tester,
  ) async {
    AgentInstallationDao(h.db).delete(secondRoverInstall.id);
    await pump(tester);

    expect(find.text('Have Flaky CLI check this'), findsOneWidget);
    await tester.tap(find.byType(OutlinedButton));
    await tester.pumpAndSettle();

    final review = SessionDao(
      h.db,
    ).getAll().firstWhere((s) => s.id != 's-work');
    expect(review.parentSessionId, 's-work');
    expect(review.parentLink, SessionLink.spawn);
    expect(review.agentInstallationId, flakyInstall.id);
    expect(review.title, 'Review · Fix the parser');
  });

  testWidgets('several installations open a menu, still never its own', (
    tester,
  ) async {
    await pump(tester);

    expect(find.text('Have another agent check this'), findsOneWidget);
    await tester.tap(find.byType(OutlinedButton));
    await tester.pumpAndSettle();

    // Both other installations, and not the one that did the work.
    expect(find.text('Flaky CLI'), findsOneWidget);
    expect(find.text('Rover CLI'), findsOneWidget);

    await tester.tap(find.text('Flaky CLI'));
    await tester.pumpAndSettle();
    expect(SessionDao(h.db).getAll(), hasLength(2));
  });

  testWidgets('the reviewer menu draws the house two-line row', (tester) async {
    // It was a dense `ListTile` in a plain `PopupMenuItem` — Material's own
    // gutter and title size, in a menu that has to read like every other one.
    await pump(tester);
    await tester.tap(find.byType(OutlinedButton));
    await tester.pumpAndSettle();

    expect(find.byType(DesktopMenuDetailItem<ReviewTarget>), findsNWidgets(2));
    // The reason to pick one over the other is on the row, not behind a hover.
    expect(find.textContaining('read and run, never write'), findsWidgets);
    expect(
      tester
          .getSize(
            find.widgetWithText(
              DesktopMenuDetailItem<ReviewTarget>,
              'Flaky CLI',
            ),
          )
          .height,
      greaterThanOrEqualTo(Chrome.menuRowTall),
    );
  });

  testWidgets('with nothing else installed it says why, and starts nothing', (
    tester,
  ) async {
    AgentInstallationDao(h.db)
      ..delete(flakyInstall.id)
      ..delete(secondRoverInstall.id);
    await pump(tester);

    final button = tester.widget<OutlinedButton>(find.byType(OutlinedButton));
    expect(button.onPressed, isNull);

    final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
    expect(tooltip.message, contains('Rover CLI'));
    expect(tooltip.message, contains('Discover agents'));

    await tester.tap(find.byType(OutlinedButton));
    await tester.pumpAndSettle();
    expect(SessionDao(h.db).getAll(), hasLength(1));
  });

  testWidgets('the tooltip says the review is capped before it is pressed', (
    tester,
  ) async {
    AgentInstallationDao(h.db).delete(secondRoverInstall.id);
    await pump(tester);

    final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
    expect(tooltip.message, contains('read and run, never write'));
  });
}
