import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/phone_shell.dart';
import 'package:karmashala/src/features/overview/application/overview_providers.dart';
import 'package:karmashala/src/features/todos/application/todos_providers.dart';
import 'package:karmashala/src/features/todos/domain/project_scope.dart';
import 'package:karmashala/src/features/todos/presentation/todos_view.dart';

import '../../features/overview/mission_fixture.dart';

/// **Todos one tap away on the phone** (owner, 2026-10-09): a Todos button
/// with the open count in the Dashboard's one-row header, Todos first under
/// More, and a session's in the peek's ⋯ — each the existing todos page.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ks-phone-todos');
  });
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // The prefs file may still be held open on Windows; the OS sweeps temp.
    }
  });

  Finder byKey(String key) => find.byKey(ValueKey(key));

  Future<ProviderContainer> pumpDashboard(
    WidgetTester tester, {
    double width = 390,
    double scale = 1,
  }) => pumpMission(
    tester,
    fixture: MissionFixture.full(),
    prefsDir: dir,
    size: Size(width, 800),
    phone: true,
    textScale: scale,
  );

  void addTodos(ProviderContainer c, int count) {
    for (var i = 0; i < count; i++) {
      c.read(todosProvider.notifier).add(body: 'Todo $i', projectId: null);
    }
  }

  for (final width in [360.0, 412.0]) {
    for (final scale in [1.0, 1.6]) {
      testWidgets('${width}px at ${scale}x: Todos sits in the one-row header', (
        tester,
      ) async {
        final c = await pumpDashboard(tester, width: width, scale: scale);
        addTodos(c, 2);
        await settleMission(tester);

        final todos = tester.getRect(byKey('overview-todos'));
        final segment = tester.getRect(byKey('overview-view'));
        final filter = tester.getRect(byKey('overview-filter-button'));
        // One row: nothing wrapped under the view switch.
        expect(todos.top, lessThan(segment.bottom));
        expect(filter.top, lessThan(segment.bottom));
        expect(segment.right, lessThanOrEqualTo(todos.left));
        expect(todos.right, lessThanOrEqualTo(width));
        // The open count, on the button.
        expect(
          find.descendant(
            of: byKey('overview-todos'),
            matching: find.text('2'),
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await unmountMission(tester);
      });

      testWidgets('${width}px at ${scale}x: it opens the todos page', (
        tester,
      ) async {
        final c = await pumpDashboard(tester, width: width, scale: scale);
        await tester.tap(byKey('overview-todos'));
        await settleMission(tester);

        expect(find.byType(TodosView), findsOneWidget);
        // A More page's one-row header (round 86) draws its own back control.
        expect(byKey('page-header-back'), findsOneWidget);
        // Quick add, then tick it off, on the page itself.
        await tester.enterText(
          find.descendant(
            of: find.byType(TodosView),
            matching: find.byType(TextField),
          ),
          'Buy milk',
        );
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await settleMission(tester);
        expect(c.read(openTodoCountProvider), 1);
        expect(find.text('Buy milk'), findsOneWidget);
        await tester.tap(find.byType(Checkbox).first);
        await settleMission(tester);
        expect(c.read(openTodoCountProvider), 0);
        expect(tester.takeException(), isNull);
        await unmountMission(tester);
      });
    }
  }

  testWidgets('no open todos: the button wears no count', (tester) async {
    await pumpDashboard(tester);
    expect(byKey('overview-todos'), findsOneWidget);
    expect(
      find.descendant(of: byKey('overview-todos'), matching: find.text('0')),
      findsNothing,
    );
    await unmountMission(tester);
  });

  testWidgets('Todos is first under More', (tester) async {
    await pumpMission(
      tester,
      fixture: MissionFixture.full(),
      prefsDir: dir,
      size: const Size(390, 844),
      phone: true,
      home: const PhoneShell(),
    );
    await tester.tap(find.text('More'));
    await settleMission(tester);

    final tiles = tester.widgetList<ListTile>(find.byType(ListTile)).toList();
    expect((tiles.first.title! as Text).data, 'Todos');
    await tester.tap(find.widgetWithText(ListTile, 'Todos'));
    await settleMission(tester);
    expect(find.byType(TodosView), findsOneWidget);
    await unmountMission(tester);
  });

  testWidgets("a session's ⋯ opens its project's todos", (tester) async {
    final c = await pumpDashboard(tester);
    c.read(overviewFocusProvider.notifier).peek('ks-r32');
    await settleMission(tester);

    await tester.tap(byKey('overview-peek-more'));
    await settleMission(tester);
    await tester.tap(byKey('overview-peek-menu:todos'));
    await settleMission(tester);

    expect(find.byType(TodosView), findsOneWidget);
    expect(c.read(todoScopeProvider), isNot(ProjectScope.unfiled));
    expect(tester.takeException(), isNull);
    await unmountMission(tester);
  });
}
