import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/todos/application/todos_providers.dart';
import 'package:karmashala/src/features/todos/data/todo_dao.dart';
import 'package:karmashala/src/features/todos/presentation/todos_view.dart';

import '../../support/fixtures.dart';

/// **A change the panel did not make.**
///
/// `TodosController` holds its list in memory and re-reads after each of its
/// own writes, which is right for everything that goes through it — the panel,
/// and `todo_add`, `todo_done` and `todo_delete`, which all call its methods.
/// It is wrong for the one writer it cannot see: another process with
/// `karmashala.sqlite` open. The owner hit that directly. Two todos were ticked
/// off by writing to the file while the app's MCP server was unreachable, and
/// the panel drew them open until the app restarted — *"you said marked done
/// but i don't see the change."*
///
/// Every write below therefore goes through a **second `TodoDao` on the same
/// database**, never through the controller: that is as close as a widget test
/// gets to a foreign writer, and it is the only shape of change these tests are
/// about.
///
/// The fix is not a poll. `CommandSnippetsController` next door holds its list
/// in memory for a stated reason — *"a surface that re-reads the table on every
/// frame of a resize is a surface that reads the table for no reason"* — and a
/// timer would trade that for a worse bargain. The panel asks at the two
/// moments somebody is about to read it, and the last test here is the one that
/// keeps the bargain honest: coming back to an unchanged list publishes nothing.
void main() {
  ({ProviderContainer container, AppDatabase db}) freshDatabase() {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    return (container: container, db: db);
  }

  Widget panel(ProviderContainer container, {required bool showing}) =>
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                SizedBox(
                  width: 320,
                  child: showing ? const TodosView() : const SizedBox(),
                ),
                const Expanded(child: SizedBox()),
              ],
            ),
          ),
        ),
      );

  /// What the row shows: ticked or not.
  bool ticked(WidgetTester tester) =>
      tester.widget<Checkbox>(find.byType(Checkbox)).value ?? false;

  test('refresh reads a row the controller never wrote', () {
    final (:container, :db) = freshDatabase();
    final todo = container
        .read(todosProvider.notifier)
        .add(body: 'Rework the tab strip');
    expect(container.read(todosProvider).single.isDone, isFalse);

    // Straight to the table, the way another process would.
    TodoDao(db).setDone(todo.id, DateTime.utc(2026, 9, 3, 12));

    expect(
      container.read(todosProvider).single.isDone,
      isFalse,
      reason: 'in-memory state cannot know; nothing has asked the table yet',
    );

    container.read(todosProvider.notifier).refresh();

    expect(container.read(todosProvider).single.isDone, isTrue);
  });

  testWidgets('the panel sees it when the window comes back, without a remount', (
    tester,
  ) async {
    final (:container, :db) = freshDatabase();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final todo = container
        .read(todosProvider.notifier)
        .add(body: 'Rework the tab strip');
    await tester.pumpWidget(panel(container, showing: true));
    await tester.pumpAndSettle();
    expect(ticked(tester), isFalse);

    // The element identity is the whole point of this test: the panel that ends
    // up showing the change has to be the *same* panel that was showing the
    // stale list. A remount would prove nothing — the app already recovered on
    // a restart.
    final panelElement = tester.element(find.byType(TodosView));

    TodoDao(db).setDone(todo.id, DateTime.utc(2026, 9, 3, 12));
    await tester.pumpAndSettle();
    expect(
      ticked(tester),
      isFalse,
      reason: 'this is the bug: the write happened and the panel is unmoved',
    );

    // The user alt-tabs away and comes back.
    container.read(windowFocusedProvider.notifier).set(false);
    await tester.pump();
    container.read(windowFocusedProvider.notifier).set(true);
    await tester.pumpAndSettle();

    expect(ticked(tester), isTrue);
    expect(find.text('DONE'), findsOneWidget);
    expect(find.text('TODOS'), findsOneWidget, reason: 'nothing left open');
    expect(
      tester.element(find.byType(TodosView)),
      same(panelElement),
      reason: 'the same panel saw it; nothing was rebuilt from scratch',
    );
  });

  testWidgets('a change made while the panel was closed shows when it opens', (
    tester,
  ) async {
    final (:container, :db) = freshDatabase();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final todo = container
        .read(todosProvider.notifier)
        .add(body: 'Rework the tab strip');
    await tester.pumpWidget(panel(container, showing: true));
    await tester.pumpAndSettle();

    // The rail switches to another surface, and the change lands while nothing
    // is watching.
    await tester.pumpWidget(panel(container, showing: false));
    await tester.pumpAndSettle();
    TodoDao(db).setDone(todo.id, DateTime.utc(2026, 9, 3, 12));

    await tester.pumpWidget(panel(container, showing: true));
    await tester.pumpAndSettle();

    expect(ticked(tester), isTrue);
    expect(find.text('DONE'), findsOneWidget);
  });

  testWidgets('coming back to an unchanged list publishes nothing', (
    tester,
  ) async {
    final (:container, db: _) = freshDatabase();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    container.read(todosProvider.notifier).add(body: 'Rework the tab strip');
    await tester.pumpWidget(panel(container, showing: true));
    await tester.pumpAndSettle();
    final before = container.read(todosProvider);

    for (var i = 0; i < 5; i++) {
      container.read(windowFocusedProvider.notifier).set(false);
      await tester.pump();
      container.read(windowFocusedProvider.notifier).set(true);
      await tester.pump();
    }

    // Five alt-tabs, five small SELECTs, and not one rebuild: `refresh`
    // publishes a difference rather than a list. A tiling window manager
    // crosses focus dozens of times a minute, and this surface must not
    // repaint for any of them.
    expect(container.read(todosProvider), same(before));
  });
}
