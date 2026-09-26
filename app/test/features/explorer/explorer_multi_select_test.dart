import 'package:agent_cli/descriptors.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/automations/presentation/resume_on_reset_dialog.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/project_import_service.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/workspace_mirror.dart';
import '../terminal/fake_instance.dart';

/// **Multi-select in the Explorer: the conventional gestures, both row kinds,
/// and filing a set of projects into a context in one go.**
///
/// The owner: "explorer multi select option, provide option to add to a context
/// all as well". A context holds projects, and a project is in at most one, so
/// the verb is *Move to*. A selection holds one kind at a time.
void main() {
  late AppDatabase db;
  late FakeDataServer server;

  setUp(() {
    db = AppDatabase.memory();
    server = FakeDataServer()..mirrorInto(db);
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    server.workspaceRows.insert(
      Workspace(id: 'w1', name: 'Game dev', createdAt: testTime),
    );
    server.projectRows.insert(project(id: 'p1', name: 'Hub', path: r'C:\hub'));
    server.projectRows.insert(
      project(id: 'p2', name: 'Alpha', path: r'C:\alpha'),
    );
    server.projectRows.insert(
      project(id: 'p3', name: 'Beta', path: r'C:\beta'),
    );
    server.repositoryRows.insert(
      repository(id: 'r1', name: 'hub', path: r'C:\hub'),
    );
    AgentInstallationDao(db).insert(agentInstallation());
    for (var i = 0; i < 4; i++) {
      mirroredServer(db).sessionRows.insert(
        Session(
          id: 'n$i',
          repositoryId: 'r1',
          agentInstallationId: 'a1',
          title: 'Session $i',
          useWorktree: false,
          status: SessionStatus.completed,
          createdAt: testTime.add(Duration(minutes: i)),
        ),
      );
    }
  });
  tearDown(() => db.close());

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    Size size = const Size(460, 900),
    bool openHub = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        await server.override(),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('n-')),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(),
        ),
        availableSystemTerminalsProvider.overrideWith(
          (ref) async => const <SystemTerminal>[],
        ),
        autoImportRunnerProvider.overrideWithValue(
          (_) async => const ImportSummary(),
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
        child: MaterialApp(
          theme: AppTheme.light().copyWith(platform: TargetPlatform.windows),
          builder: (context, inner) => UiDensity.wrap(context, inner!),
          home: const Scaffold(body: ExplorerPanel()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (openHub) {
      await tester.tap(find.text('Hub'));
      await tester.pumpAndSettle();
    }
    return container;
  }

  Future<void> clickWith(
    WidgetTester tester,
    String text,
    LogicalKeyboardKey key,
  ) async {
    await tester.sendKeyDownEvent(key);
    await tester.tap(find.text(text));
    await tester.sendKeyUpEvent(key);
    await tester.pumpAndSettle();
  }

  Future<void> rightClick(WidgetTester tester, String text) async {
    await tester.tap(find.text(text), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
  }

  String? contextOf(String projectId) =>
      server.projectRows.getById(projectId)!.workspaceId;

  List<String> sessionTitlesTopDown(WidgetTester tester) {
    final titles = [for (var i = 0; i < 4; i++) 'Session $i'];
    titles.sort(
      (a, b) => tester
          .getTopLeft(find.text(a))
          .dy
          .compareTo(tester.getTopLeft(find.text(b)).dy),
    );
    return titles;
  }

  group('the gestures', () {
    testWidgets('Ctrl-click ticks a row without the toolbar, and unticks it', (
      tester,
    ) async {
      final container = await pump(tester);

      await clickWith(tester, 'Session 1', LogicalKeyboardKey.controlLeft);
      expect(find.text('1 session selected'), findsOneWidget);
      expect(
        container.read(selectedSessionIdProvider),
        isNull,
        reason: 'a modified click selects; it does not open',
      );

      await clickWith(tester, 'Session 1', LogicalKeyboardKey.controlLeft);
      expect(find.text('0 selected'), findsOneWidget);
    });

    testWidgets('Cmd-click does the same on a Mac keyboard', (tester) async {
      await pump(tester);
      await clickWith(tester, 'Session 2', LogicalKeyboardKey.metaLeft);
      expect(find.text('1 session selected'), findsOneWidget);
    });

    testWidgets('Shift-click selects the range in the order on screen', (
      tester,
    ) async {
      await pump(tester);
      final order = sessionTitlesTopDown(tester);

      await clickWith(tester, order[0], LogicalKeyboardKey.controlLeft);
      await clickWith(tester, order[2], LogicalKeyboardKey.shiftLeft);

      expect(find.text('3 sessions selected'), findsOneWidget);
      final middle = tester.widget<SessionCard>(
        find.ancestor(
          of: find.text(order[1]),
          matching: find.byType(SessionCard),
        ),
      );
      expect(middle.ticked, isTrue);
    });

    testWidgets('Ctrl+A selects every visible row of the focused kind', (
      tester,
    ) async {
      await pump(tester);
      Focus.of(tester.element(find.text('Session 0'))).requestFocus();
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(find.text('4 sessions selected'), findsOneWidget);
    });

    testWidgets('Space ticks the focused row, and Escape leaves', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.byTooltip('Select'));
      await tester.pumpAndSettle();
      Focus.of(tester.element(find.text('Session 3'))).requestFocus();
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(find.text('1 session selected'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(Checkbox), findsNothing);
      expect(find.text('1 session selected'), findsNothing);
    });

    testWidgets(
      'Select on a row\'s menu enters the mode with that row ticked',
      (tester) async {
        await pump(tester);
        await rightClick(tester, 'Alpha');
        await tester.tap(find.text('Select'));
        await tester.pumpAndSettle();

        expect(find.text('1 project selected'), findsOneWidget);
      },
    );
  });

  group('one kind at a time', () {
    testWidgets('once a session is ticked a project cannot join', (
      tester,
    ) async {
      await pump(tester);
      await clickWith(tester, 'Session 0', LogicalKeyboardKey.controlLeft);

      final alphaBox = find.descendant(
        of: find.ancestor(
          of: find.text('Alpha'),
          matching: find.byType(ProjectCard),
        ),
        matching: find.byType(Checkbox),
      );
      expect(alphaBox, findsOneWidget, reason: 'drawn, so the rule is visible');
      expect(tester.widget<Checkbox>(alphaBox).onChanged, isNull);
      expect(find.byTooltip('This selection holds sessions'), findsWidgets);

      await clickWith(tester, 'Alpha', LogicalKeyboardKey.controlLeft);
      expect(find.text('1 session selected'), findsOneWidget);
    });
  });

  group('filing projects into a context', () {
    Future<void> selectAlphaAndBeta(WidgetTester tester) async {
      await clickWith(tester, 'Alpha', LogicalKeyboardKey.controlLeft);
      await clickWith(tester, 'Beta', LogicalKeyboardKey.controlLeft);
      expect(find.text('2 projects selected'), findsOneWidget);
    }

    testWidgets('Move to an existing context moves them all, and Undo puts '
        'them back', (tester) async {
      await pump(tester, openHub: false);
      await selectAlphaAndBeta(tester);

      await tester.tap(find.widgetWithText(TextButton, 'Move to…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Game dev').last);
      await tester.pumpAndSettle();

      expect(contextOf('p2'), 'w1');
      expect(contextOf('p3'), 'w1');
      expect(find.text('Moved 2 projects to Game dev.'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(contextOf('p2'), isNull);
      expect(contextOf('p3'), isNull);
    });

    testWidgets('New context… creates one and moves them all into it', (
      tester,
    ) async {
      await pump(tester, openHub: false);
      await selectAlphaAndBeta(tester);

      await tester.tap(find.widgetWithText(TextButton, 'Move to…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New context…'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find
            .descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(TextField),
            )
            .first,
        'Tools',
      );
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      final tools = server.workspaceRows.getAll().singleWhere(
        (w) => w.name == 'Tools',
      );
      expect(contextOf('p2'), tools.id);
      expect(contextOf('p3'), tools.id);
    });

    testWidgets('Remove from context takes them out, and keeps them', (
      tester,
    ) async {
      server.projectRows.setWorkspace('p2', 'w1');
      server.projectRows.setWorkspace('p3', 'w1');
      await pump(tester, openHub: false);
      await selectAlphaAndBeta(tester);

      await tester.tap(find.widgetWithText(TextButton, 'Remove'));
      await tester.pumpAndSettle();

      expect(contextOf('p2'), isNull);
      expect(contextOf('p3'), isNull);
      expect(server.projectRows.getById('p2'), isNotNull);
      expect(
        find.text('Removed 2 projects from their context.'),
        findsOneWidget,
      );
    });

    testWidgets('a right-click on a ticked row acts on the whole selection', (
      tester,
    ) async {
      await pump(tester, openHub: false);
      await selectAlphaAndBeta(tester);

      await rightClick(tester, 'Alpha');
      await tester.tap(find.text('Move 2 projects to Game dev'));
      await tester.pumpAndSettle();

      expect(contextOf('p2'), 'w1');
      expect(contextOf('p3'), 'w1');
    });
  });

  group('resuming when usage resets', () {
    testWidgets('a right-click on ticked sessions opens the dialog for all of '
        'them', (tester) async {
      await pump(tester);
      await clickWith(tester, 'Session 0', LogicalKeyboardKey.controlLeft);
      await clickWith(tester, 'Session 1', LogicalKeyboardKey.controlLeft);

      await rightClick(tester, 'Session 0');
      await tester.tap(find.text('Resume 2 sessions when usage resets…'));
      await tester.pumpAndSettle();

      final dialog = tester.widget<ResumeOnResetDialog>(
        find.byType(ResumeOnResetDialog),
      );
      expect(dialog.sessionIds, unorderedEquals(['n0', 'n1']));
      expect(find.text('2 sessions'), findsOneWidget);
    });
  });

  group('deleting', () {
    testWidgets('a right-click Delete on a ticked session still asks first', (
      tester,
    ) async {
      await pump(tester);
      await clickWith(tester, 'Session 0', LogicalKeyboardKey.controlLeft);
      await clickWith(tester, 'Session 1', LogicalKeyboardKey.controlLeft);

      await rightClick(tester, 'Session 0');
      await tester.tap(find.text('Delete 2 sessions…'));
      await tester.pumpAndSettle();

      expect(find.text('Delete 2 sessions?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(mirroredServer(db).sessionRows.getById('n0'), isNotNull);
    });
  });

  group('the bar at the pane\'s narrow widths', () {
    for (final width in [200.0, 240.0]) {
      testWidgets('folds its verbs into one menu at ${width.toInt()}px', (
        tester,
      ) async {
        await pump(tester, size: Size(width, 800), openHub: false);
        await clickWith(tester, 'Alpha', LogicalKeyboardKey.controlLeft);

        expect(tester.takeException(), isNull);
        expect(find.widgetWithText(TextButton, 'Move to…'), findsNothing);
        await tester.tap(find.byTooltip('Selection actions'));
        await tester.pumpAndSettle();
        expect(find.text('Move to Game dev'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('what a tick costs', () {
    List<int> identities<T extends Widget>(WidgetTester tester) => [
      for (final card in tester.widgetList<T>(find.byType(T)))
        identityHashCode(card),
    ];

    testWidgets('ticking a project rebuilds that row and no other', (
      tester,
    ) async {
      await pump(tester);
      await clickWith(tester, 'Alpha', LogicalKeyboardKey.controlLeft);
      final projects = identities<ProjectCard>(tester);
      final sessions = identities<SessionCard>(tester);

      await clickWith(tester, 'Beta', LogicalKeyboardKey.controlLeft);

      final after = identities<ProjectCard>(tester);
      var moved = 0;
      for (var i = 0; i < after.length; i++) {
        if (after[i] != projects[i]) moved++;
      }
      expect(moved, 1);
      expect(identities<SessionCard>(tester), sessions);
    });
  });
}
