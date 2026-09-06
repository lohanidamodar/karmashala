import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/theme/app_theme.dart';
import 'package:karmashala/src/app/theme/design_tokens.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/todos/application/todos_providers.dart';
import 'package:karmashala/src/features/todos/domain/project_scope.dart';
import 'package:karmashala/src/features/todos/presentation/todos_view.dart';

import '../terminal/fake_instance.dart';
import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';

/// A todo at the length the owner’s own list actually runs to: past 200
/// characters. Long is the normal case on this surface, not an edge one, which
/// is why every field here wraps.
const longTodo =
    'Rework the tab strip so a session that has been renamed still shows the '
    'branch it is on, and make the overflow menu list the panes that no '
    'longer fit rather than silently dropping them off the end of the row.';

void main() {
  /// The panel this lives in, at the width it actually gets on a desktop, with
  /// two projects so "which one" is a real question.
  ///
  /// [platform] is what decides the density — a mouse or a thumb — and so
  /// whether the row's `⋮` is drawn at rest. Windows by default, because
  /// this pane is read on the desktop; the companion runs it on Android.
  Future<ProviderContainer> pump(
    WidgetTester tester, {
    TargetPlatform platform = TargetPlatform.windows,
  }) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db)
      ..insert(project())
      ..insert(project(id: 'p2', name: 'Karmashala', path: r'C:\src\k'));

    // The row menu names the session it would send to, so building one
    // resolves `focusedSessionIdProvider` and with it the terminal
    // controller — whose autosave timer would outlive a widget test. The
    // faked terminal is the sanctioned way to hold that still; nothing here
    // is about the terminal.
    final container = ProviderContainer(
      overrides: fakeTerminalOverrides(database: db),
    );
    addTearDown(container.dispose);

    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light().copyWith(platform: platform),
          // Exactly what a root does: ask the platform, install the density.
          builder: (context, inner) => UiDensity.wrap(context, inner!),
          home: const Scaffold(
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

  /// Puts a mouse on [finder] and leaves it there.
  Future<TestGesture> hover(WidgetTester tester, Finder finder) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(() => gesture.removePointer());
    await gesture.moveTo(tester.getCenter(finder));
    await tester.pumpAndSettle();
    return gesture;
  }

  /// Opens a row's menu the way a mouse does: hover the row, then press the
  /// `⋮` the hover just revealed.
  Future<void> openRowMenu(WidgetTester tester, String body) async {
    await hover(tester, find.text(body));
    await tester.tap(find.byTooltip('Actions for “$body”'));
    await tester.pumpAndSettle();
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

    await openRowMenu(tester, 'second');
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

    await openRowMenu(tester, 'unfiled for now');
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

    await openRowMenu(tester, 'temporary');
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(container.read(todosProvider), isEmpty);
  });

  /// The rule the Explorer set and this pane now keeps: a row's actions are on
  /// the row, reachable four ways, and the button that duplicates them is
  /// drawn when a pointer or the keyboard is on the row — or always, where
  /// there is no pointer at all.
  ///
  /// The keyboard path is asserted rather than assumed. Hiding a button is
  /// only honest while the menu can still be opened without a mouse, and the
  /// Explorer's own history is the reason to test the paths that *look* fine:
  /// a bug there discarded every mouse-driven choice on every row while
  /// right-click and Shift+F10 went on working.
  group('the row menu, four ways in', () {
    testWidgets('the button is not drawn until a pointer is on the row', (
      tester,
    ) async {
      final container = await pump(tester);
      container.read(todosProvider.notifier).add(body: 'quiet at rest');
      await tester.pumpAndSettle();

      expect(find.byTooltip('Actions for “quiet at rest”'), findsNothing);

      await hover(tester, find.text('quiet at rest'));
      expect(find.byTooltip('Actions for “quiet at rest”'), findsOneWidget);
    });

    testWidgets('but is always drawn on a touch surface, which has no hover', (
      tester,
    ) async {
      final container = await pump(tester, platform: TargetPlatform.android);
      container.read(todosProvider.notifier).add(body: 'thumbed');
      await tester.pumpAndSettle();

      expect(find.byTooltip('Actions for “thumbed”'), findsOneWidget);
    });

    testWidgets('a right-click opens it, which is the desktop gesture', (
      tester,
    ) async {
      final container = await pump(tester);
      container.read(todosProvider.notifier).add(body: 'right-clicked');
      await tester.pumpAndSettle();

      await tester.tap(find.text('right-clicked'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      expect(find.text('Delete'), findsOneWidget);
    });

    testWidgets('Shift+F10 opens it from the focused row', (tester) async {
      final container = await pump(tester);
      container.read(todosProvider.notifier).add(body: 'keyboard only');
      await tester.pumpAndSettle();

      // The line is one of the row's focus stops — the tick is the other —
      // and focusing it is what a Tab does.
      Focus.of(tester.element(find.text('keyboard only'))).requestFocus();
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
      await tester.sendKeyEvent(LogicalKeyboardKey.f10);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
      await tester.pumpAndSettle();

      expect(find.text('Delete'), findsOneWidget);
    });

    testWidgets('so does the Menu key', (tester) async {
      final container = await pump(tester);
      container.read(todosProvider.notifier).add(body: 'menu key');
      await tester.pumpAndSettle();

      Focus.of(tester.element(find.text('menu key'))).requestFocus();
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pumpAndSettle();

      expect(find.text('Delete'), findsOneWidget);
    });

    testWidgets('and the keyboard reveals the button it did not need', (
      tester,
    ) async {
      final container = await pump(tester);
      container.read(todosProvider.notifier).add(body: 'focused');
      await tester.pumpAndSettle();
      expect(find.byTooltip('Actions for “focused”'), findsNothing);

      Focus.of(tester.element(find.text('focused'))).requestFocus();
      await tester.pumpAndSettle();

      expect(find.byTooltip('Actions for “focused”'), findsOneWidget);
    });

    testWidgets('a mouse-driven choice is not swallowed by its own menu', (
      tester,
    ) async {
      // The Explorer's bug, asserted here so this pane cannot repeat it: the
      // menu's modal barrier takes the hover off the row, and a button that
      // unmounts under its own menu makes `showMenu` drop the result.
      final container = await pump(tester);
      container.read(todosProvider.notifier).add(body: 'delete me');
      await tester.pumpAndSettle();

      final gesture = await hover(tester, find.text('delete me'));
      await tester.tap(find.byTooltip('Actions for “delete me”'));
      await tester.pumpAndSettle();
      // The barrier is up; take the pointer off the row, as one really does.
      await gesture.moveTo(const Offset(1000, 500));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(container.read(todosProvider), isEmpty);
    });
  });

  group('a todo is a sentence, so nothing here scrolls sideways', () {
    testWidgets('the composer grows down as the line runs long', (
      tester,
    ) async {
      await pump(tester);
      final composer = find.byType(TextField).first;
      final empty = tester.getSize(composer);

      await tester.enterText(composer, longTodo);
      await tester.pumpAndSettle();

      final filled = tester.getSize(composer);
      expect(
        filled.height,
        greaterThan(empty.height),
        reason:
            'a single-line field scrolls AxisDirection.right, and a todo this '
            'long is the ordinary case here, not an edge one',
      );
      expect(
        filled.width,
        empty.width,
        reason: 'it grows downwards; the panel does not get wider',
      );
      // Pinned above the list, so it stops rather than eating the panel.
      expect(tester.widget<TextField>(composer).maxLines, 4);
      expect(tester.widget<TextField>(composer).minLines, 1);
    });

    testWidgets('Enter files the todo, and never breaks the line', (
      tester,
    ) async {
      final container = await pump(tester);

      await write(tester, longTodo);

      // The whole sentence, in one piece: Enter committed rather than
      // inserting a newline nobody could then get rid of.
      expect(container.read(todosProvider).single.body, longTodo);
      expect(container.read(todosProvider).single.body, isNot(contains('\n')));

      // The half of that contract the *platform* reads. Left to itself a
      // multi-line field asks for TextInputType.multiline, and both the
      // Windows key handler and a soft keyboard would then turn Return into a
      // newline and never deliver the action — which on a phone would leave
      // no way to save at all.
      final composer = tester.widget<TextField>(find.byType(TextField).first);
      expect(composer.keyboardType, TextInputType.text);
      expect(composer.textInputAction, TextInputAction.done);
    });

    testWidgets('the row editor wraps too, and Enter commits it', (
      tester,
    ) async {
      final container = await pump(tester);
      final todos = container.read(todosProvider.notifier);
      todos.add(body: 'short');
      todos.add(body: longTodo);
      await tester.pumpAndSettle();

      await tester.tap(find.text('short'));
      await tester.pumpAndSettle();
      final oneLine = tester.getSize(find.byType(TextField).last).height;
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      await tester.tap(find.text(longTodo));
      await tester.pumpAndSettle();
      final editor = find.byType(TextField).last;
      expect(
        tester.getSize(editor).height,
        greaterThan(oneLine),
        reason: 'editing a long todo must not mean dragging it sideways',
      );
      // Uncapped, unlike the composer: the row it replaces already draws the
      // whole body, so the line being read never jumps or shrinks.
      final field = tester.widget<TextField>(editor);
      expect(field.maxLines, isNull);
      expect(field.keyboardType, TextInputType.text);
      expect(field.textInputAction, TextInputAction.done);

      await tester.enterText(editor, '$longTodo, twice over');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      final edited = container
          .read(todosProvider)
          .firstWhere((todo) => todo.body != 'short');
      expect(edited.body, '$longTodo, twice over');
      expect(edited.body, isNot(contains('\n')));
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('the list draws the whole todo, wrapped', (tester) async {
      final container = await pump(tester);
      final todos = container.read(todosProvider.notifier);
      todos.add(body: 'short');
      todos.add(body: longTodo);
      await tester.pumpAndSettle();

      final short = tester.getSize(find.text('short'));
      final long = tester.getSize(find.text(longTodo));

      expect(
        long.height,
        greaterThan(short.height * 3),
        reason: 'a todo you cannot read is as bad as one you cannot type',
      );
      expect(long.width, lessThanOrEqualTo(short.width + 320));
      // Nothing truncates it: no maxLines, no ellipsis.
      final text = tester.widget<Text>(find.text(longTodo));
      expect(text.maxLines, isNull);
      expect(text.overflow, isNull);
    });

    testWidgets('a long todo fits at a phone width and a desktop one', (
      tester,
    ) async {
      // The panel is 240px at its narrowest, which is narrower than any phone;
      // this pumps the surface at the full window width instead, so the two
      // form factors CLAUDE.md asks about are both actually measured.
      await expectSurvivesWindowMatrix(
        tester,
        matrix: const [
          WindowCell('400x800 (phone-like)', Size(400, 800)),
          desktopWindow,
        ],
        because:
            'a 200-character todo is the owner’s ordinary case, and it '
            'has to wrap rather than clip at either width',
        build: () {
          final db = AppDatabase.memory();
          addTearDown(db.close);
          ExecutionEnvironmentDao(db).upsert(windowsEnv());
          ProjectDao(db).insert(project());
          final container = ProviderContainer(
            overrides: [databaseProvider.overrideWithValue(db)],
          );
          addTearDown(container.dispose);
          container.read(todosProvider.notifier).add(
            body: longTodo,
            projectId: 'p1',
          );
          return UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(
              home: Scaffold(body: TodosView()),
            ),
          );
        },
      );
    });
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
