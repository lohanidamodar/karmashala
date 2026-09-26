import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/notes/application/composer_draft.dart';
import 'package:karmashala/src/features/notes/application/notes_providers.dart';
import 'package:karmashala/src/features/notes/presentation/notes_view.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/workspace_mirror.dart';

/// **What changing session costs the notes list: nothing.**
///
/// `NotesView.build` used to watch the selected session and hand it to every
/// card, so switching session repainted all of them. Narrowing that to the
/// cards with no session of their own left exactly one subscriber — the card
/// whose always-drawn Send button had to *name* the fallback it would use.
///
/// It no longer names it. The button resolves its target when it is clicked,
/// so **no card in this panel subscribes to a session provider at all** and a
/// tab click cannot reach the list. That is what these tests pin.
///
/// Counted, never timed: the suite runs at `--concurrency=4`, so a wall-clock
/// assertion over a few milliseconds is a coin toss, while widget builds are
/// countable exactly.
///
/// What it measures (2026-09-06), over five notes of which one was written in
/// the panel rather than captured from a session:
///
/// | change                     | watch the fallback | resolve on click |
/// | -------------------------- | -----------------: | ---------------: |
/// | selecting another session  |                  1 |                0 |
/// | re-selecting the same one  |                  0 |                0 |
/// | capturing a note           |                  6 |                6 |
///
/// The last row is the control: six notes, six cards, unchanged by this work.
/// Without it the 0 above could be bought by a list that stopped listening —
/// and the send in the first test is the other half of the same guard, because
/// a card that never repaints is worth nothing if it also sends nowhere.
void main() {
  Future<ProviderContainer> pump(WidgetTester tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    final server = FakeDataServer()..mirrorInto(db);
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        await server.override(),
      ],
    );
    addTearDown(container.dispose);
    final sessions = container.read(sessionsDataProvider)
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
    // The one note with no session of its own — the last card that had any
    // reason to read the selection.
    notes.capture(body: 'written here');

    // Tall enough that all five cards are built, so "0 builds" below is a claim
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

  testWidgets('changing session repaints no card at all', (tester) async {
    final container = await pump(tester);

    container.read(selectedSessionIdProvider.notifier).select('s2');
    await tester.pumpAndSettle();

    expect(
      NotesView.debugCardBuildCount,
      0,
      reason:
          'four notes carry their own session, and the fifth resolves its '
          'target when it is clicked — no card reads a session to draw itself',
    );
    // The source-less card says the same thing before and after, because what
    // it says no longer depends on which session is up.
    final send = find.byTooltip('Send to the active session');
    expect(send, findsOneWidget);

    // And it followed the switch anyway: resolved on the click, not watched.
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(container.read(composerDraftProvider)['s2'], 'written here');
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
