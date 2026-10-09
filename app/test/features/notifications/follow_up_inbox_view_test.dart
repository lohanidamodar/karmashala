import 'package:karmashala_ui/menus.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/notifications/application/attention_inbox.dart';
import 'package:karmashala/src/features/notifications/presentation/attention_inbox_view.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/geometry.dart' show kOverviewPaneId;
import 'package:karmashala_session/session.dart';
import 'package:karmashala_verification/verification.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../terminal/fake_instance.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';
import '../../support/test_machine.dart';

/// What the user actually sees: the follow-up as a row in the one list the app
/// has, with the words that let them decide whether to open the session.
void main() {
  late TestMachine db;
  late ProviderContainer container;
  late FakeDataServer server;

  setUp(() {
    db = TestMachine();
    server = FakeDataServer().runsOn(db)
      ..environmentRows.upsert(windowsEnv())
      ..projectRows.insert(project())
      ..repositoryRows.insert(repository());
    server.installationRows.insert(agentInstallation());
  });

  Future<void> pump(WidgetTester tester) async {
    container = ProviderContainer(
      overrides: [
        await server.override(),
        // Opening a session reveals it, on the dashboard's tab.
        ...fakeTerminalOverrides(machine: db),
        clockProvider.overrideWithValue(
          FixedClock(testTime.add(const Duration(hours: 2))),
        ),
        agentSessionStatusProvider.overrideWith(
          (ref, id) => const Stream<AgentStatusReport>.empty(),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: SizedBox(width: 360, child: AttentionInboxView()),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('a crashed session is listed with what it left', (tester) async {
    db.server.sessionRows.insert(
      session(id: 's1', title: 'Fix login', status: SessionStatus.failed),
    );
    await pump(tester);

    expect(find.text('Fix login'), findsOneWidget);
    expect(find.textContaining('Needs a follow-up'), findsOneWidget);
    expect(find.textContaining('Ended in error'), findsOneWidget);
    // No decision was recorded, and the row says so rather than filling the
    // line with something plausible.
    expect(find.textContaining('Nothing else was recorded'), findsOneWidget);
    // The area header every sidebar area has: its name, then how many are new.
    expect(find.text('Inbox'), findsOneWidget);
    expect(find.text('1 new'), findsOneWidget);
  });

  testWidgets('an unfinished check is quoted in the run\'s own words', (
    tester,
  ) async {
    db.server.sessionRows.insert(
      session(
        id: 's1',
        title: 'Ship the parser',
        status: SessionStatus.completed,
      ),
    );
    db.server.verificationRows.insertRun(
      VerificationRun(
        id: 'v1',
        title: 'the parser round-trips a nested list',
        target: const VerificationTarget.browser('https://example.com'),
        startedAt: testTime,
        artifactDirectory: 'C:/art/v1',
        sessionId: 's1',
      ),
    );
    await pump(tester);

    expect(
      find.textContaining('the parser round-trips a nested list'),
      findsOneWidget,
    );
  });

  testWidgets('dismissing it empties the list for good', (tester) async {
    db.server.sessionRows.insert(
      session(id: 's1', title: 'Fix login', status: SessionStatus.failed),
    );
    await pump(tester);

    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pump();

    expect(find.text('Nothing needs you.'), findsOneWidget);
    expect(db.server.followUpRows.open(), isEmpty);
  });

  testWidgets('reading the inbox does not clear a follow-up', (tester) async {
    db.server.sessionRows.insert(
      session(id: 's1', title: 'Fix login', status: SessionStatus.failed),
    );
    await pump(tester);

    await tester.tap(find.byTooltip('Mark all read'));
    await tester.pump();

    // Still listed — reading a notice is not dealing with it — but no longer
    // counted against the badge.
    expect(find.text('Fix login'), findsOneWidget);
    expect(find.text('Inbox'), findsOneWidget);
    expect(find.text('1 new'), findsNothing);
  });

  testWidgets('tapping it opens the session it came from', (tester) async {
    db.server.sessionRows.insert(
      session(id: 's1', title: 'Fix login', status: SessionStatus.failed),
    );
    await pump(tester);

    await tester.tap(find.text('Fix login'));
    await tester.pump();

    // Opened, and nothing else: the offer is a way in, never a relaunch. With
    // no tab here, on the dashboard rather than selected (round 81).
    expect(container.read(selectedSessionIdProvider), isNull);
    expect(
      container
          .read(terminalSessionsControllerProvider.notifier)
          .tabIdOfPane(kOverviewPaneId),
      isNotNull,
    );
    expect(container.read(attentionInboxProvider).items.single.seen, isTrue);
    expect(db.server.sessionRows.getById('s1')!.status, SessionStatus.failed);
  });

  /// The same rule the Todos and Notes panes keep, on the pane whose rows
  /// already carried their verbs: the row's actions are reachable by
  /// right-click, `Shift+F10` and the Menu key, not only by aiming at a glyph.
  ///
  /// Nothing is hidden here — an inbox row's two buttons are both verbs the row
  /// is *for* — so the menu is a second way to the same things plus the one the
  /// row's own tap performs.
  group('the row menu', () {
    testWidgets('a right-click opens it', (tester) async {
      db.server.sessionRows.insert(
        session(id: 's1', title: 'Fix login', status: SessionStatus.failed),
      );
      await pump(tester);

      await tester.tap(find.text('Fix login'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      expect(find.text('Open the session'), findsOneWidget);
      expect(find.text('Dismiss'), findsOneWidget);
    });

    testWidgets('Shift+F10 opens it from the focused row', (tester) async {
      db.server.sessionRows.insert(
        session(id: 's1', title: 'Fix login', status: SessionStatus.failed),
      );
      await pump(tester);

      Focus.of(tester.element(find.text('Fix login'))).requestFocus();
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
      await tester.sendKeyEvent(LogicalKeyboardKey.f10);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
      await tester.pumpAndSettle();

      expect(find.text('Open the session'), findsOneWidget);
    });

    testWidgets('so does the Menu key, and Dismiss on it clears the row', (
      tester,
    ) async {
      db.server.sessionRows.insert(
        session(id: 's1', title: 'Fix login', status: SessionStatus.failed),
      );
      await pump(tester);

      Focus.of(tester.element(find.text('Fix login'))).requestFocus();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pumpAndSettle();

      // The menu row, not the button that carries the same tooltip.
      await tester.tap(find.widgetWithText(DesktopMenuItem<String>, 'Dismiss'));
      await tester.pumpAndSettle();

      expect(find.text('Nothing needs you.'), findsOneWidget);
      expect(db.server.followUpRows.open(), isEmpty);
    });
  });
}
