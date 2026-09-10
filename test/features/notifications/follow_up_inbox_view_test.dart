import 'package:karmashala_ui/menus.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/follow_ups/data/follow_up_dao.dart';
import 'package:karmashala/src/features/notifications/application/attention_inbox.dart';
import 'package:karmashala/src/features/notifications/presentation/attention_inbox_view.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala/src/features/verification/data/verification_dao.dart';
import 'package:karmashala/src/features/verification/domain/verification_run.dart';
import 'package:karmashala/src/features/verification/domain/verification_target.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// What the user actually sees: the follow-up as a row in the one list the app
/// has, with the words that let them decide whether to open the session.
void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
  });
  tearDown(() => db.close());

  Future<void> pump(WidgetTester tester) async {
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
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
          home: Scaffold(body: SizedBox(width: 360, child: AttentionInboxView())),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('a crashed session is listed with what it left', (tester) async {
    SessionDao(db).insert(
      session(id: 's1', title: 'Fix login', status: SessionStatus.failed),
    );
    await pump(tester);

    expect(find.text('Fix login'), findsOneWidget);
    expect(find.textContaining('Needs a follow-up'), findsOneWidget);
    expect(find.textContaining('Ended in error'), findsOneWidget);
    // No decision was recorded, and the row says so rather than filling the
    // line with something plausible.
    expect(find.textContaining('Nothing else was recorded'), findsOneWidget);
    expect(find.text('INBOX  ·  1 NEW'), findsOneWidget);
  });

  testWidgets('an unfinished check is quoted in the run\'s own words', (
    tester,
  ) async {
    SessionDao(db).insert(
      session(id: 's1', title: 'Ship the parser', status: SessionStatus.completed),
    );
    VerificationDao(db).insertRun(
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
    SessionDao(db).insert(
      session(id: 's1', title: 'Fix login', status: SessionStatus.failed),
    );
    await pump(tester);

    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pump();

    expect(find.text('Nothing needs you.'), findsOneWidget);
    expect(FollowUpDao(db).open(), isEmpty);
  });

  testWidgets('reading the inbox does not clear a follow-up', (tester) async {
    SessionDao(db).insert(
      session(id: 's1', title: 'Fix login', status: SessionStatus.failed),
    );
    await pump(tester);

    await tester.tap(find.text('Mark all read'));
    await tester.pump();

    // Still listed — reading a notice is not dealing with it — but no longer
    // counted against the badge.
    expect(find.text('Fix login'), findsOneWidget);
    expect(find.text('INBOX'), findsOneWidget);
  });

  testWidgets('tapping it opens the session it came from', (tester) async {
    SessionDao(db).insert(
      session(id: 's1', title: 'Fix login', status: SessionStatus.failed),
    );
    await pump(tester);

    await tester.tap(find.text('Fix login'));
    await tester.pump();

    // Opened, and nothing else: the offer is a way in, never a relaunch.
    expect(container.read(selectedSessionIdProvider), 's1');
    expect(
      container.read(attentionInboxProvider).items.single.seen,
      isTrue,
    );
    expect(SessionDao(db).getById('s1')!.status, SessionStatus.failed);
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
      SessionDao(db).insert(
        session(id: 's1', title: 'Fix login', status: SessionStatus.failed),
      );
      await pump(tester);

      await tester.tap(find.text('Fix login'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      expect(find.text('Open the session'), findsOneWidget);
      expect(find.text('Dismiss'), findsOneWidget);
    });

    testWidgets('Shift+F10 opens it from the focused row', (tester) async {
      SessionDao(db).insert(
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
      SessionDao(db).insert(
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
      expect(FollowUpDao(db).open(), isEmpty);
    });
  });
}
