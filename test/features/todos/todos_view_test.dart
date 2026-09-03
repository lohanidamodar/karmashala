import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/todos/application/todos_providers.dart';
import 'package:karmashala/src/features/todos/domain/project_scope.dart';
import 'package:karmashala/src/features/todos/presentation/todos_view.dart';

import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';

void main() {
  /// The panel this lives in, at the width it actually gets on a desktop, with
  /// two projects so "which one" is a real question.
  Future<ProviderContainer> pump(WidgetTester tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db)
      ..insert(project())
      ..insert(project(id: 'p2', name: 'Karmashala', path: r'C:\src\k'));

    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);

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
                SizedBox(width: 320, child: TodosView()),
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

  Future<void> write(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField).first, text);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }

  testWidgets('the empty panel says whose list this is', (tester) async {
    await pump(tester);

    expect(find.textContaining('No todos yet'), findsOneWidget);
    // The one thing this surface has to say for itself: it is not a third
    // inbox. Nothing arrives here on its own.
    expect(
      find.textContaining('nothing appears here on its own'),
      findsOneWidget,
    );
    expect(find.textContaining('Inbox'), findsOneWidget);
  });

  testWidgets('typing one adds it, filed under nothing', (tester) async {
    final container = await pump(tester);

    await write(tester, 'Rework the tab strip');

    expect(find.text('Rework the tab strip'), findsOneWidget);
    expect(find.text('TODOS  ·  1'), findsOneWidget);
    final todo = container.read(todosProvider).single;
    expect(
      todo.projectId,
      isNull,
      reason: 'written while showing everything, so filed under nothing',
    );
    expect(todo.isDone, isFalse);
  });

  testWidgets('one written under a project is filed there', (tester) async {
    final container = await pump(tester);
    container
        .read(todoScopeProvider.notifier)
        .select(const ProjectScope.project('p2'));
    await tester.pumpAndSettle();

    // The hint says where it will land before it lands there.
    expect(find.text('New todo in Karmashala'), findsOneWidget);
    await write(tester, 'Ship the todo panel');

    expect(container.read(todosProvider).single.projectId, 'p2');
  });

  testWidgets('the filter narrows to a project, and to nothing at all', (
    tester,
  ) async {
    final container = await pump(tester);
    final todos = container.read(todosProvider.notifier);
    todos.add(body: 'filed under demo', projectId: 'p1');
    todos.add(body: 'filed under nothing');
    await tester.pumpAndSettle();

    expect(find.text('filed under demo'), findsOneWidget);
    expect(find.text('filed under nothing'), findsOneWidget);

    container
        .read(todoScopeProvider.notifier)
        .select(const ProjectScope.project('p1'));
    await tester.pumpAndSettle();
    expect(find.text('filed under demo'), findsOneWidget);
    expect(find.text('filed under nothing'), findsNothing);

    // "No project" is a place you can go and look, not the remainder.
    container.read(todoScopeProvider.notifier).select(ProjectScope.unfiled);
    await tester.pumpAndSettle();
    expect(find.text('filed under demo'), findsNothing);
    expect(find.text('filed under nothing'), findsOneWidget);
  });

  testWidgets('ticking one off keeps it, under DONE', (tester) async {
    final container = await pump(tester);
    container.read(todosProvider.notifier).add(body: 'Rework the tab strip');
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();

    // Still there — a mis-tick is one click to undo, so nothing vanishes.
    expect(find.text('Rework the tab strip'), findsOneWidget);
    expect(find.text('DONE'), findsOneWidget);
    expect(container.read(todosProvider).single.isDone, isTrue);
    // The header counts what is left to do, which is now nothing.
    expect(find.text('TODOS'), findsOneWidget);

    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(container.read(todosProvider).single.isDone, isFalse);
    expect(find.text('DONE'), findsNothing);
  });

  testWidgets('clearing the finished ones takes only those', (tester) async {
    final container = await pump(tester);
    final todos = container.read(todosProvider.notifier);
    todos.add(body: 'still open');
    final done = todos.add(body: 'already done');
    todos.setDone(done.id, true);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Clear 1 finished todo'));
    await tester.pumpAndSettle();

    expect(find.text('already done'), findsNothing);
    expect(find.text('still open'), findsOneWidget);
    expect(container.read(todosProvider).single.body, 'still open');
  });

  testWidgets('a tap on the line edits it in place', (tester) async {
    final container = await pump(tester);
    container.read(todosProvider.notifier).add(body: 'Rework the tab strip');
    await tester.pumpAndSettle();

    await tester.tap(find.text('Rework the tab strip'));
    await tester.pumpAndSettle();
    // Two fields now: the composer and the row being edited.
    expect(find.byType(TextField), findsNWidgets(2));

    await tester.enterText(find.byType(TextField).last, 'Rework it at 720');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(container.read(todosProvider).single.body, 'Rework it at 720');
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('the row menu moves one up the list', (tester) async {
    final container = await pump(tester);
    final todos = container.read(todosProvider.notifier);
    todos.add(body: 'first');
    todos.add(body: 'second');
    await tester.pumpAndSettle();
    expect(container.read(todosProvider).map((t) => t.body), [
      'first',
      'second',
    ]);

    await tester.tap(find.byTooltip('Actions for “second”'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move up'));
    await tester.pumpAndSettle();

    expect(container.read(todosProvider).map((t) => t.body), [
      'second',
      'first',
    ]);
  });

  testWidgets('the row menu files one under a project', (tester) async {
    final container = await pump(tester);
    container.read(todosProvider.notifier).add(body: 'unfiled for now');
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Actions for “unfiled for now”'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('File under…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Karmashala'));
    await tester.pumpAndSettle();

    expect(container.read(todosProvider).single.projectId, 'p2');
    // And the row now says which one, because the panel is showing all of them.
    expect(find.text('Karmashala'), findsOneWidget);
  });

  testWidgets('the row menu deletes one', (tester) async {
    final container = await pump(tester);
    container.read(todosProvider.notifier).add(body: 'temporary');
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Actions for “temporary”'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(container.read(todosProvider), isEmpty);
  });

  testWidgets('survives the window matrix', (tester) async {
    await expectSurvivesWindowMatrix(
      tester,
      because:
          'the side panel is 240px at its narrowest and this row carries a '
          'tick, a line, a project name and a menu',
      build: () {
        final db = AppDatabase.memory();
        addTearDown(db.close);
        ExecutionEnvironmentDao(db).upsert(windowsEnv());
        ProjectDao(db).insert(project());
        final container = ProviderContainer(
          overrides: [databaseProvider.overrideWithValue(db)],
        );
        addTearDown(container.dispose);
        final todos = container.read(todosProvider.notifier);
        todos.add(
          body: 'A todo long enough to need the whole width of a narrow panel',
          projectId: 'p1',
        );
        final done = todos.add(body: 'and one already finished');
        todos.setDone(done.id, true);
        return UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: Row(
                children: [
                  SizedBox(width: 240, child: TodosView()),
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
