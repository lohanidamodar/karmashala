import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/notes/application/notes_providers.dart';
import 'package:karmashala/src/features/notes/presentation/notes_view.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

/// **What changing session costs the notes list.**
///
/// `NotesView.build` watched the selected session and handed it to every card,
/// so switching session repainted all of them — including every note captured
/// from a session of its own, which never reads the selection at all. The
/// selection is only the *fallback* target for a note that has no session, so
/// only those cards subscribe to it now.
///
/// Counted, never timed: the suite runs at `--concurrency=4`, so a wall-clock
/// assertion over a few milliseconds is a coin toss, while widget builds are
/// countable exactly.
///
/// What it measures (2026-09-03), over five notes of which one was written in
/// the panel rather than captured from a session:
///
/// | change                     | card builds before | after |
/// | -------------------------- | -----------------: | ----: |
/// | selecting another session  |                  5 |     1 |
/// | re-selecting the same one  |                  0 |     0 |
/// | capturing a note           |                  6 |     6 |
///
/// The last row is the control: six notes, six cards, unchanged by this work.
/// Without it the 1 above could be bought by a list that stopped listening.
void main() {
  Future<ProviderContainer> pump(WidgetTester tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());

    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    final sessions = container.read(sessionDaoProvider)
      ..insert(session(title: 'Toolbar rework'))
      ..insert(session(id: 's2', title: 'Diff panel'));
    expect(sessions.getById('s2')?.title, 'Diff panel');

    final notes = container.read(notesProvider.notifier);
    for (var i = 0; i < 4; i++) {
      notes.capture(
        body: 'captured note $i',
        sourceSessionId: 's1',
        sourceRepositoryId: 'r1',
        sourceMessageOrdinal: i,
        sourceMessageRole: 'agent',
      );
    }
    // The one note with no session of its own. Its send button names whichever
    // session is on screen, so it is the only card the selection can change.
    notes.capture(body: 'written here');

    // Tall enough that all five cards are built, so "1 build" below is a claim
    // about cards that exist rather than cards the list never reached.
    tester.view.physicalSize = const Size(1440, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                SizedBox(width: 320, child: NotesView()),
                Expanded(child: SizedBox()),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // The header counts what the list holds, and says it unambiguously — a
    // note's body is also its title, so its text appears twice per card.
    expect(find.text('NOTES  ·  5'), findsOneWidget);
    NotesView.debugCardBuildCount = 0;
    return container;
  }

  testWidgets('changing session repaints only the card that names it', (
    tester,
  ) async {
    final container = await pump(tester);

    container.read(selectedSessionIdProvider.notifier).select('s2');
    await tester.pumpAndSettle();

    expect(
      NotesView.debugCardBuildCount,
      1,
      reason:
          'four notes carry their own session and cannot be affected by the '
          'selection; the fifth is the fallback and has to be redrawn',
    );
    // And it really did change: the fallback card now offers the new session.
    expect(
      find.byTooltip('Send to Diff panel’s message box'),
      findsOneWidget,
    );
  });

  testWidgets('selecting the same session again costs nothing at all', (
    tester,
  ) async {
    final container = await pump(tester);
    container.read(selectedSessionIdProvider.notifier).select('s2');
    await tester.pumpAndSettle();
    NotesView.debugCardBuildCount = 0;

    container.read(selectedSessionIdProvider.notifier).select('s2');
    await tester.pumpAndSettle();

    expect(NotesView.debugCardBuildCount, 0);
  });

  testWidgets('...but capturing a note still redraws the list', (tester) async {
    // The control. Without it the zero above could be bought by a list that
    // stopped listening to anything.
    final container = await pump(tester);

    container.read(notesProvider.notifier).capture(body: 'and one more');
    await tester.pumpAndSettle();

    expect(
      NotesView.debugCardBuildCount,
      6,
      reason: 'six notes, one build each',
    );
  });
}
