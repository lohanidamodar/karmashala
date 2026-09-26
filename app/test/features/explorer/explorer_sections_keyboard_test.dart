import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/explorer/application/explorer_sections.dart';
import 'package:karmashala/src/features/explorer/application/explorer_view_mode.dart';
import 'package:karmashala/src/features/explorer/application/session_selection.dart';
import 'package:karmashala/src/features/explorer/domain/explorer_section.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_keyboard.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

/// **The saved views are a list of rows too, and take the tree's keys.**
///
/// `explorer_keyboard_test` holds the keys; this holds that the saved sections
/// are driven by the same ones, over the rows in the order *this* list draws
/// them — which is also what a Shift-click ranges over here.
void main() {
  late TestMachine db;
  late FakeDataServer server;

  const failures = 'section-ended-in-failure';

  setUp(() {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    seedDefaultSections(server);
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(
      project(id: 'p1', name: 'Demo', path: r'C:\src\demo'),
    );
    server.repositoryRows.insert(repository());
    server.installationRows.insert(agentInstallation());
    for (final (i, title) in ['Alpha fix', 'Bravo fix', 'Delta fix'].indexed) {
      db.server.sessionRows.insert(
        session(
          id: 'f$i',
          title: title,
          status: SessionStatus.failed,
        ).copyWith(createdAt: testTime.subtract(Duration(minutes: i))),
      );
    }
    db.server.sessionRows.insert(
      session(id: 'r0', title: 'Kept close', status: SessionStatus.completed),
    );
  });

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    bool openFailures = true,
  }) async {
    tester.view.physicalSize = const Size(460, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(machine: db),
        await server.override(),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: FakeCommandRunner()),
        ),
        agentSessionStatusProvider.overrideWith(
          (ref, id) => const Stream<AgentStatusReport>.empty(),
        ),
      ],
    );
    addTearDown(container.dispose);
    final settings = container.read(settingsControllerProvider.notifier);
    settings.setHideEmptySections(false);
    settings.togglePinnedSession('r0');
    final sections = container.read(explorerSectionsProvider.notifier);
    sections.setCollapsed(kPinnedSectionId, false);
    if (openFailures) sections.setCollapsed(failures, false);
    container.read(explorerShowingViewsProvider.notifier).toggle();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light().copyWith(platform: TargetPlatform.windows),
          builder: (context, inner) => UiDensity.wrap(context, inner!),
          home: const Scaffold(body: ExplorerPanel()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  /// The id of the row holding keyboard focus, as the list names it.
  String? focused() => FocusManager.instance.primaryFocus?.context
      ?.findAncestorWidgetOfExactType<ExplorerKeyboardRow>()
      ?.id;

  bool searchHasFocus() {
    final context = FocusManager.instance.primaryFocus?.context;
    return context != null &&
        context.findAncestorWidgetOfExactType<ExplorerSearchField>() != null;
  }

  Future<void> press(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    int times = 1,
  }) async {
    for (var i = 0; i < times; i++) {
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
    }
  }

  Future<void> focusRow(WidgetTester tester, String text) async {
    Focus.of(tester.element(find.text(text))).requestFocus();
    await tester.pumpAndSettle();
  }

  const titles = {
    'session:f0': 'Alpha fix',
    'session:f1': 'Bravo fix',
    'session:f2': 'Delta fix',
  };
  String sessionId(String rowId) => rowId.substring('session:'.length);

  /// The failed sessions' row ids, top to bottom as drawn.
  List<String> failedTopDown(WidgetTester tester) => titles.keys.toList()
    ..sort(
      (a, b) => tester
          .getTopLeft(find.text(titles[a]!))
          .dy
          .compareTo(tester.getTopLeft(find.text(titles[b]!)).dy),
    );

  const down = LogicalKeyboardKey.arrowDown;
  const up = LogicalKeyboardKey.arrowUp;
  const left = LogicalKeyboardKey.arrowLeft;
  const right = LogicalKeyboardKey.arrowRight;

  testWidgets('up and down move a row at a time through sections and their '
      'rows, in the order drawn; a line of prose is not a stop', (
    tester,
  ) async {
    final container = await pump(tester);
    // Open and empty: it draws its sentence, which the keys pass over.
    container
        .read(explorerSectionsProvider.notifier)
        .setCollapsed('section-checks-failing', false);
    await tester.pumpAndSettle();
    expect(find.textContaining('Delivery strip'), findsOneWidget);
    await focusRow(tester, 'Pinned');

    final seen = [focused()];
    for (var i = 0; i < 7; i++) {
      await press(tester, down);
      seen.add(focused());
    }
    expect(seen, [
      'section:$kPinnedSectionId',
      'session:r0',
      'section:section-checks-failing',
      'section:section-awaiting-input',
      'section:$failures',
      ...failedTopDown(tester),
    ]);

    await press(tester, down);
    expect(focused(), seen.last, reason: 'the last row is the last row');
    await press(tester, up, times: 4);
    expect(focused(), 'section:section-awaiting-input');
  });

  testWidgets('Home and End go to the first and the last row', (tester) async {
    await pump(tester);
    await focusRow(tester, 'Awaiting input');

    await press(tester, LogicalKeyboardKey.end);
    expect(focused(), failedTopDown(tester).last);
    await press(tester, LogicalKeyboardKey.home);
    expect(focused(), 'section:$kPinnedSectionId');
  });

  testWidgets('right opens a folded section, then steps into it; left steps '
      'out to it, then folds it', (tester) async {
    await pump(tester, openFailures: false);
    await focusRow(tester, 'Ended in failure');
    expect(find.text('Alpha fix'), findsNothing);

    await press(tester, right);
    expect(find.text('Alpha fix'), findsOneWidget);
    expect(focused(), 'section:$failures', reason: 'opening does not move');

    await press(tester, right);
    expect(focused(), failedTopDown(tester).first);

    await press(tester, down);
    await press(tester, left);
    expect(focused(), 'section:$failures');

    await press(tester, left);
    expect(find.text('Alpha fix'), findsNothing);
    expect(focused(), 'section:$failures');
  });

  testWidgets('typing goes to the next row whose title starts with it', (
    tester,
  ) async {
    await pump(tester);
    await focusRow(tester, 'Pinned');

    await tester.sendKeyEvent(LogicalKeyboardKey.keyE, character: 'e');
    await tester.pumpAndSettle();
    expect(focused(), 'section:$failures');

    await tester.pump(Latency.typeAhead + const Duration(milliseconds: 50));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB, character: 'b');
    await tester.pumpAndSettle();
    expect(focused(), 'session:f1');
  });

  testWidgets('down leaves the search field for the first section, and up on '
      'it goes back', (tester) async {
    await pump(tester);
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(searchHasFocus(), isTrue);

    await press(tester, down);
    expect(focused(), 'section:$kPinnedSectionId');

    await press(tester, up);
    expect(searchHasFocus(), isTrue);
  });

  testWidgets('Shift and an arrow extend the selection, in selection mode', (
    tester,
  ) async {
    final container = await pump(tester);
    final order = failedTopDown(tester);
    container
        .read(sessionSelectionProvider.notifier)
        .toggle(sessionId(order[0]));
    await tester.pumpAndSettle();
    await focusRow(tester, titles[order[0]]!);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await press(tester, down, times: 2);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();

    expect(container.read(sessionSelectionProvider).ids, {'f0', 'f1', 'f2'});
  });

  testWidgets('a Shift-click ranges over the rows this list draws, across a '
      'section header', (tester) async {
    final container = await pump(tester);
    final order = failedTopDown(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.text('Kept close'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(find.text(titles[order[1]]!));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();

    expect(container.read(sessionSelectionProvider).ids, {
      'r0',
      sessionId(order[0]),
      sessionId(order[1]),
    });
  });

  testWidgets('Ctrl+A selects every session this list draws', (tester) async {
    final container = await pump(tester);
    await focusRow(tester, 'Alpha fix');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(container.read(sessionSelectionProvider).ids, {
      'r0',
      'f0',
      'f1',
      'f2',
    });
  });

  testWidgets('F2 renames the focused session here too', (tester) async {
    await pump(tester);
    await focusRow(tester, 'Kept close');

    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await tester.pumpAndSettle();
    expect(find.text('Rename session'), findsOneWidget);
  });
}

/// The four sections a new workspace starts with — seeded by the server's
/// own schema, which the fake does not have.
void seedDefaultSections(FakeDataServer server) {
  for (final (id, name, kind, position) in const [
    ('section-pinned', 'Pinned', 'pinned', 0),
    ('section-checks-failing', 'Checks failing', 'checksFailing', 1),
    ('section-awaiting-input', 'Awaiting input', 'awaitingInput', 2),
    ('section-ended-in-failure', 'Ended in failure', 'endedInFailure', 3),
  ]) {
    server.sectionRows.put(
      StoredSection(id: id, name: name, kind: kind, position: position),
    );
  }
}
