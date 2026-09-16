import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/notes/application/notes_providers.dart';
import 'package:karmashala/src/features/notes/presentation/notes_view.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';
import 'package:karmashala/src/features/todos/domain/project_scope.dart';

import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';

/// Which project a note belongs to, and how it says so.
///
/// A note has always recorded where it *came from* — a session and that
/// session's repository. What it could not say is where the user **filed** it,
/// which is the difference between provenance (a fact about the past, not
/// editable) and filing (a choice, editable, and clearable back to nothing).
void main() {
  Future<ProviderContainer> pump(WidgetTester tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db)
      ..insert(project())
      ..insert(project(id: 'p2', name: 'Karmashala', path: r'C:\src\k'));
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());

    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    container.read(sessionDaoProvider).insert(session(title: 'Toolbar rework'));

    tester.view.physicalSize = const Size(1440, 900);
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
    return container;
  }

  /// Puts a mouse on [finder] and leaves it there.
  Future<TestGesture> hover(WidgetTester tester, Finder finder) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(() => gesture.removePointer());
    await gesture.moveTo(tester.getCenter(finder));
    await tester.pumpAndSettle();
    return gesture;
  }

  /// Opens a card's menu the way a mouse does: hover the card, then press the
  /// `⋮` the hover just revealed, then pick [choice].
  Future<void> pickFromRowMenu(
    WidgetTester tester,
    String title,
    String choice,
  ) async {
    // `.first` because a short note's title and its body are the same run of
    // text, drawn twice on the one card.
    await hover(tester, find.text(title).first);
    await tester.tap(find.byTooltip('Actions for “$title”'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(choice));
    await tester.pumpAndSettle();
  }

  testWidgets('a note captured from a session is filed under its project', (
    tester,
  ) async {
    final container = await pump(tester);

    container
        .read(notesProvider.notifier)
        .capture(
          body: 'about the toolbar',
          sourceSessionId: 's1',
          sourceRepositoryId: 'r1',
        );
    await tester.pumpAndSettle();

    // A lookup, not a guess: a repository belongs to exactly one project.
    expect(container.read(notesProvider).single.projectId, 'p1');
    // And the card leads with it, because that is what the filter acts on.
    expect(find.textContaining('Demo  ·  From Toolbar rework'), findsOneWidget);
  });

  testWidgets('a note written in the panel is filed under nothing', (
    tester,
  ) async {
    final container = await pump(tester);

    container.read(notesProvider.notifier).capture(body: 'written here');
    await tester.pumpAndSettle();

    expect(container.read(notesProvider).single.projectId, isNull);
    // No project to name, so the origin line says only where it came from.
    expect(find.text('Written here'), findsOneWidget);
  });

  testWidgets('the filter narrows to a project, and to nothing at all', (
    tester,
  ) async {
    final container = await pump(tester);
    final notes = container.read(notesProvider.notifier);
    notes.capture(body: 'filed under demo', projectId: 'p1');
    notes.capture(body: 'filed under nothing');
    await tester.pumpAndSettle();
    expect(find.text('NOTES  ·  2'), findsOneWidget);

    container
        .read(noteScopeProvider.notifier)
        .select(const ProjectScope.project('p1'));
    await tester.pumpAndSettle();
    expect(find.text('NOTES  ·  1'), findsOneWidget);
    // Twice per card: a note with no title of its own is named by its first
    // line, so the same words are the heading and the preview.
    expect(find.text('filed under demo'), findsNWidgets(2));
    expect(find.text('filed under nothing'), findsNothing);

    // "No project" is somewhere to look, not the remainder of a filter.
    container.read(noteScopeProvider.notifier).select(ProjectScope.unfiled);
    await tester.pumpAndSettle();
    expect(find.text('filed under nothing'), findsNWidgets(2));
    expect(find.text('filed under demo'), findsNothing);

    // An empty filter does not claim there are no notes.
    container
        .read(noteScopeProvider.notifier)
        .select(const ProjectScope.project('p2'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No notes under this project'), findsOneWidget);
    expect(find.text('No notes yet.'), findsNothing);
  });

  testWidgets('an edit can re-file a note and can unfile it', (tester) async {
    final container = await pump(tester);
    final notes = container.read(notesProvider.notifier);
    final note = notes.capture(body: 'about the toolbar', projectId: 'p1');
    await tester.pumpAndSettle();

    await pickFromRowMenu(tester, 'about the toolbar', 'Edit note');
    // The dialog opens on the note's current filing.
    expect(find.text('Demo'), findsOneWidget);
    await tester.tap(find.text('Demo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('No project').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(
      container.read(notesProvider).single.projectId,
      isNull,
      reason: 'null from the dialog means "unfile it", not "leave it alone"',
    );
    // Origin survives the re-filing: where it came from is not editable.
    expect(container.read(notesProvider).single.id, note.id);
  });

  testWidgets('survives the window matrix', (tester) async {
    await expectSurvivesWindowMatrix(
      tester,
      because:
          'the header now carries a project name beside the title, and the '
          'panel is 240px at its narrowest',
      build: () {
        final db = AppDatabase.memory();
        addTearDown(db.close);
        ExecutionEnvironmentDao(db).upsert(windowsEnv());
        ProjectDao(db).insert(project(name: 'A project with a long name'));
        RepositoryDao(db).insert(repository());
        AgentInstallationDao(db).insert(agentInstallation());
        final container = ProviderContainer(
          overrides: [databaseProvider.overrideWithValue(db)],
        );
        addTearDown(container.dispose);
        container.read(sessionDaoProvider).insert(session(title: 'Toolbar'));
        container
            .read(notesProvider.notifier)
            .capture(
              body: 'A note long enough to need the width of a narrow panel',
              sourceSessionId: 's1',
              sourceRepositoryId: 'r1',
            );
        container
            .read(noteScopeProvider.notifier)
            .select(const ProjectScope.project('p1'));
        return UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: Row(
                children: [
                  SizedBox(width: 240, child: NotesView()),
                  Expanded(child: SizedBox()),
                ],
              ),
            ),
          ),
        );
      },
    );
  });
}
