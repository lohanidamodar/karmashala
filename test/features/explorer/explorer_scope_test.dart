import 'package:agent_cli/descriptors.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/project_import_service.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/explorer/application/explorer_tree_nodes.dart';
import 'package:karmashala/src/features/explorer/application/explorer_tree_provider.dart';
import 'package:karmashala/src/features/explorer/application/session_context.dart';
import 'package:karmashala/src/features/explorer/application/session_selection.dart';
import 'package:karmashala/src/features/explorer/presentation/environment_rows.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_project_row.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_scope_bar.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_tree_rows.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/ssh/data/ssh_host_dao.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/data/system_terminal_service.dart';
import 'package:karmashala/src/features/workspaces/application/workspaces_controller.dart';
import 'package:karmashala/src/features/workspaces/data/workspace_dao.dart';
import 'package:karmashala/src/features/workspaces/domain/workspace.dart';
import 'package:karmashala/src/features/workspaces/domain/workspace_scope.dart';
import 'package:karmashala/src/features/workspaces/presentation/workspaces_dialog.dart';
import 'package:karmashala_ssh/connection.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// **The Explorer is two levels: a header, and what is under it.**
///
/// It was five — machine, `PROJECTS`, context, project, session — and the
/// owner's word for it was "too many". The machine is a choice in the scope
/// bar now and the context a sticky label, so everything the three lost levels
/// carried has to be somewhere else. This file is the list of where: each test
/// names an affordance the old tree had and finds it in the new one.
void main() {
  late AppDatabase db;

  /// Three machines — one of them holding nothing — two contexts that hold
  /// projects and one that does not, and a project in no context.
  void seed({bool machines = true, bool contexts = true}) {
    final environments = ExecutionEnvironmentDao(db)..upsert(windowsEnv());
    if (machines) {
      environments
        ..upsert(wslEnv())
        ..upsert(sshEnvFixture());
      SshHostDao(db).upsert(
        SshHost(
          id: 'h1',
          name: 'build-box',
          host: 'build.example.com',
          port: 22,
          username: 'dev',
          authMethod: SshAuthMethod.password,
          createdAt: testTime,
        ),
      );
    }
    if (contexts) {
      for (final (id, name) in [
        ('w1', 'Client work'),
        ('w2', 'Game dev'),
        ('w3', 'Shelf'),
      ]) {
        WorkspaceDao(
          db,
        ).insert(Workspace(id: id, name: name, createdAt: testTime));
      }
    }
    final projects = ProjectDao(db);
    String? filed(String id) => contexts ? id : null;
    projects
      ..insert(
        project(
          id: 'p1',
          name: 'proc-nepal',
          path: r'C:\src\proc',
          workspaceId: filed('w1'),
        ),
      )
      ..insert(
        project(
          id: 'p2',
          name: 'roguelike',
          path: r'C:\src\rogue',
          workspaceId: filed('w2'),
        ),
      )
      ..insert(project(id: 'p3', name: 'scratch', path: r'C:\src\scratch'));
    if (machines) {
      projects.insert(
        project(
          id: 'p4',
          name: 'relay',
          path: '/srv/relay',
          environmentId: 'ssh:h1',
          workspaceId: filed('w1'),
        ),
      );
    }
    AgentInstallationDao(db).insert(agentInstallation());
  }

  setUp(() => db = AppDatabase.memory());
  tearDown(() => db.close());

  ProviderContainer newContainer() {
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
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
    return container;
  }

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    // Wide enough that every chip fits in the test font, whose glyphs are
    // squares: the narrow cases ask for their own width.
    Size size = const Size(760, 900),
    double textScale = 1,
    ProviderContainer? container,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final scope = container ?? newContainer();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: scope,
        child: MaterialApp(
          theme: AppTheme.light().copyWith(platform: TargetPlatform.windows),
          builder: (context, inner) => MediaQuery.withClampedTextScaling(
            minScaleFactor: textScale,
            maxScaleFactor: textScale,
            child: UiDensity.wrap(context, inner!),
          ),
          home: const Scaffold(body: ExplorerPanel()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return scope;
  }

  /// What the list draws, top down: headers in capitals, projects by name.
  List<String> drawn(WidgetTester tester) {
    final rows = <(double, String)>[];
    for (final element in find.byType(ExplorerGroupHeader).evaluate()) {
      final label = element.widget as ExplorerGroupHeader;
      rows.add((
        tester.getTopLeft(find.byWidget(label)).dy,
        label.label.toUpperCase(),
      ));
    }
    for (final element in find.byType(ExplorerProjectRow).evaluate()) {
      final row = element.widget as ExplorerProjectRow;
      rows.add((tester.getTopLeft(find.byWidget(row)).dy, row.project.name));
    }
    rows.sort((a, b) => a.$1.compareTo(b.$1));
    return [for (final row in rows) row.$2];
  }

  Finder inMenu(String label) => find.descendant(
    of: find.byWidgetPredicate((widget) => widget is PopupMenuEntry),
    matching: find.text(label),
  );

  Finder chip(String label) => find.descendant(
    of: find.byType(ExplorerContextChips),
    matching: find.text(label),
  );

  Future<void> hover(WidgetTester tester, Finder finder) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(finder));
    await tester.pumpAndSettle();
  }

  group('the machine, in the scope bar', () {
    testWidgets('is not drawn with one machine: there is nothing to choose', (
      tester,
    ) async {
      seed(machines: false);
      await pump(tester);

      expect(find.byType(ExplorerEnvironmentSwitcher), findsNothing);
      expect(drawn(tester), [
        'CLIENT WORK',
        'proc-nepal',
        'GAME DEV',
        'roguelike',
        'NO CONTEXT',
        'scratch',
        'TERMINALS',
      ]);
    });

    testWidgets('lists every machine with its mark, its name and how much is '
        'on it — an empty one too', (tester) async {
      seed();
      await pump(tester);

      await tester.tap(find.byType(ExplorerEnvironmentSwitcher));
      await tester.pumpAndSettle();

      expect(inMenu('All environments'), findsOneWidget);
      expect(inMenu('4 projects'), findsOneWidget);
      expect(inMenu('Windows'), findsOneWidget);
      expect(inMenu('3 projects'), findsOneWidget);
      expect(inMenu('Ubuntu'), findsOneWidget);
      expect(
        inMenu('No projects yet'),
        findsOneWidget,
        reason: 'a machine holding nothing is where a terminal is opened',
      );
      expect(inMenu('build-box'), findsOneWidget);
      expect(inMenu('1 project'), findsOneWidget);
    });

    testWidgets('choosing one narrows the list to it, and survives a restart', (
      tester,
    ) async {
      seed();
      final container = await pump(tester);
      expect(drawn(tester), contains('relay'));
      expect(drawn(tester), contains('BUILD-BOX · TERMINALS'));

      await tester.tap(find.byType(ExplorerEnvironmentSwitcher));
      await tester.pumpAndSettle();
      await tester.tap(inMenu('Windows'));
      await tester.pumpAndSettle();

      expect(drawn(tester), [
        'CLIENT WORK',
        'proc-nepal',
        'GAME DEV',
        'roguelike',
        'NO CONTEXT',
        'scratch',
        'TERMINALS',
      ]);
      expect(
        container.read(settingsControllerProvider).explorerEnvironmentScope,
        'windows',
      );
      expect(
        newContainer().read(explorerEnvironmentScopeProvider).environmentId,
        'windows',
        reason: 'kept in settings, like the folds',
      );

      await tester.tap(find.byType(ExplorerEnvironmentSwitcher));
      await tester.pumpAndSettle();
      await tester.tap(inMenu('All environments'));
      await tester.pumpAndSettle();
      expect(drawn(tester), contains('relay'));
    });

    testWidgets('with every machine listed, a project says which it is on', (
      tester,
    ) async {
      seed();
      final container = await pump(tester);
      Finder row(String name) => find.ancestor(
        of: find.text(name),
        matching: find.byType(ExplorerProjectRow),
      );

      expect(
        find.descendant(of: row('relay'), matching: find.text('build-box')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row('scratch'), matching: find.text('Windows')),
        findsOneWidget,
      );

      container
          .read(settingsControllerProvider.notifier)
          .setExplorerEnvironmentScope('ssh:h1');
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: row('relay'), matching: find.text('build-box')),
        findsNothing,
        reason: 'the scope bar says it; the row does not repeat it',
      );
    });

    testWidgets('a stored machine that has gone shows everything', (
      tester,
    ) async {
      seed();
      final container = newContainer();
      container
          .read(settingsControllerProvider.notifier)
          .setExplorerEnvironmentScope('ssh:gone');
      await pump(tester, container: container);

      expect(
        container.read(explorerEnvironmentScopeProvider).environmentId,
        isNull,
      );
      expect(drawn(tester), contains('relay'));
    });

    testWidgets('an empty machine in scope says so, and keeps its terminals', (
      tester,
    ) async {
      seed();
      final container = newContainer();
      container
          .read(settingsControllerProvider.notifier)
          .setExplorerEnvironmentScope('wsl:Ubuntu');
      await pump(tester, container: container);

      expect(find.text('No projects on this machine yet.'), findsOneWidget);
      expect(drawn(tester), ['TERMINALS']);
    });
  });

  group('what the machine row carried', () {
    testWidgets('its + — a terminal on that machine — is on its Terminals '
        'header', (tester) async {
      seed();
      final container = await pump(tester);
      expect(container.read(terminalSessionsControllerProvider).tabs, isEmpty);

      await hover(tester, find.text('BUILD-BOX · TERMINALS'));
      await tester.tap(find.byTooltip('Open a terminal on build-box'));
      await tester.pumpAndSettle();

      expect(
        container.read(terminalSessionsControllerProvider).tabs,
        hasLength(1),
      );
    });

    testWidgets('and in the switcher\'s menu, for the machine in scope', (
      tester,
    ) async {
      seed();
      final container = newContainer();
      container
          .read(settingsControllerProvider.notifier)
          .setExplorerEnvironmentScope('ssh:h1');
      await pump(tester, container: container);

      await tester.tap(find.byType(ExplorerEnvironmentSwitcher));
      await tester.pumpAndSettle();
      await tester.tap(inMenu('Open a terminal on build-box'));
      await tester.pumpAndSettle();

      expect(
        container.read(terminalSessionsControllerProvider).tabs,
        hasLength(1),
      );
    });

    testWidgets('Terminals starts folded on every launch, whatever is stored', (
      tester,
    ) async {
      seed();
      final container = await pump(tester);

      expect(
        container
            .read(explorerTreeProvider)
            .nodes
            .whereType<TerminalsHeaderNode>()
            .every((node) => !node.expanded && node.count == null),
        isTrue,
        reason: 'opening one dials a machine; a launch dials nobody (§19)',
      );
    });
  });

  group('the context chips', () {
    testWidgets('are not drawn while there are no contexts, and neither is a '
        'header', (tester) async {
      seed(contexts: false, machines: false);
      await pump(tester);

      expect(chip('All'), findsNothing);
      expect(drawn(tester), [
        'proc-nepal',
        'roguelike',
        'scratch',
        'TERMINALS',
      ]);
    });

    testWidgets('one narrows the list to its context; All puts it back', (
      tester,
    ) async {
      seed(machines: false);
      await pump(tester);

      await tester.tap(chip('Game dev'));
      await tester.pumpAndSettle();
      expect(drawn(tester), ['GAME DEV', 'roguelike', 'TERMINALS']);

      await tester.tap(chip('No context'));
      await tester.pumpAndSettle();
      expect(drawn(tester), ['NO CONTEXT', 'scratch', 'TERMINALS']);

      await tester.tap(chip('All'));
      await tester.pumpAndSettle();
      expect(drawn(tester), hasLength(7));
    });

    testWidgets('a context holding nothing has a chip, and says so', (
      tester,
    ) async {
      seed(machines: false);
      await pump(tester);

      await tester.tap(chip('Shelf'));
      await tester.pumpAndSettle();
      expect(find.text('No projects in Shelf yet.'), findsOneWidget);
    });

    testWidgets('the choice survives a restart', (tester) async {
      seed(machines: false);
      await pump(tester);
      await tester.tap(chip('Game dev'));
      await tester.pumpAndSettle();

      expect(
        newContainer().read(workspaceScopeProvider),
        const WorkspaceScope.of('w2'),
      );
    });

    testWidgets('a stored context that was deleted shows everything', (
      tester,
    ) async {
      seed(machines: false);
      newContainer()
          .read(settingsControllerProvider.notifier)
          .setExplorerContextScope(const WorkspaceScope.of('gone').stored);

      expect(newContainer().read(workspaceScopeProvider), WorkspaceScope.all);
    });

    testWidgets('it is the scope Quick Open switches: one state, two views', (
      tester,
    ) async {
      seed(machines: false);
      final container = await pump(tester);

      container
          .read(workspaceScopeProvider.notifier)
          .select(const WorkspaceScope.of('w1'));
      await tester.pumpAndSettle();

      expect(drawn(tester), ['CLIENT WORK', 'proc-nepal', 'TERMINALS']);
      expect(
        tester
            .widget<Semantics>(
              find
                  .ancestor(
                    of: chip('Client work'),
                    matching: find.byWidgetPredicate(
                      (w) => w is Semantics && w.properties.selected != null,
                    ),
                  )
                  .first,
            )
            .properties
            .selected,
        isTrue,
        reason: 'and said to a screen reader, not only drawn',
      );
    });

    testWidgets('a filter never hides the project on screen', (tester) async {
      seed(machines: false);
      final container = await pump(tester);
      await tester.tap(find.text('scratch'));
      await tester.pumpAndSettle();

      await tester.tap(chip('Game dev'));
      await tester.pumpAndSettle();

      expect(drawn(tester), [
        'GAME DEV',
        'roguelike',
        'NO CONTEXT',
        'scratch',
        'TERMINALS',
      ]);
      expect(container.read(selectedProjectIdProvider), 'p3');
    });

    testWidgets('chips that do not fit fold into the … menu, and the one in '
        'force never does', (tester) async {
      seed(machines: false);
      for (var i = 0; i < 6; i++) {
        WorkspaceDao(db).insert(
          Workspace(id: 'x$i', name: 'Zebra crossing $i', createdAt: testTime),
        );
      }
      final container = await pump(tester, size: const Size(240, 900));
      expect(tester.takeException(), isNull);
      expect(chip('All'), findsOneWidget);
      expect(chip('Zebra crossing 5'), findsNothing);

      await tester.tap(find.byTooltip(RegExp(r'^Contexts — \d+ more$')));
      await tester.pumpAndSettle();
      await tester.tap(inMenu('Zebra crossing 5'));
      await tester.pumpAndSettle();

      expect(
        container.read(workspaceScopeProvider),
        const WorkspaceScope.of('x5'),
      );
      expect(chip('Zebra crossing 5'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('what the context row carried, and what it never did', () {
    testWidgets('a header folds, and the fold is kept', (tester) async {
      seed(machines: false);
      final container = await pump(tester);

      await tester.tap(find.text('CLIENT WORK'));
      await tester.pumpAndSettle();

      expect(drawn(tester), isNot(contains('proc-nepal')));
      expect(
        container.read(settingsControllerProvider).collapsedExplorerNodes,
        [contextHeaderId('w1')],
      );
    });

    testWidgets('its menu renames the context', (tester) async {
      seed(machines: false);
      final container = await pump(tester);

      await tester.tap(find.text('GAME DEV'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(inMenu('Rename or describe…'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Games');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(
        container.read(workspacesControllerProvider).map((w) => w.name),
        contains('Games'),
      );
      expect(find.text('GAMES'), findsOneWidget);
    });

    testWidgets('deletes it after asking, and keeps its projects', (
      tester,
    ) async {
      seed(machines: false);
      final container = await pump(tester);

      await hover(tester, find.text('GAME DEV'));
      await tester.tap(find.byTooltip('Context actions'));
      await tester.pumpAndSettle();
      await tester.tap(inMenu('Delete context…'));
      await tester.pumpAndSettle();
      expect(find.text('Delete context?'), findsOneWidget);
      expect(container.read(workspacesControllerProvider), hasLength(3));

      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(container.read(workspacesControllerProvider), hasLength(2));
      expect(ProjectDao(db).getById('p2')!.workspaceId, isNull);
      expect(drawn(tester), containsAllInOrder(['NO CONTEXT', 'roguelike']));
    });

    testWidgets('shows only itself, then everything again', (tester) async {
      seed(machines: false);
      final container = await pump(tester);

      await tester.tap(find.text('GAME DEV'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(inMenu('Show only Game dev'));
      await tester.pumpAndSettle();
      expect(
        container.read(workspaceScopeProvider),
        const WorkspaceScope.of('w2'),
      );

      await tester.tap(find.text('GAME DEV'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(inMenu('Show every context'));
      await tester.pumpAndSettle();
      expect(container.read(workspaceScopeProvider), WorkspaceScope.all);
    });

    testWidgets('makes a new context, and opens the manager', (tester) async {
      seed(machines: false);
      final container = await pump(tester);

      await tester.tap(find.text('NO CONTEXT'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(inMenu('Delete context…'), findsNothing);
      expect(inMenu('Rename or describe…'), findsNothing);
      await tester.tap(inMenu('New context…'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Tools');
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(container.read(workspacesControllerProvider), hasLength(4));

      await tester.tap(find.byTooltip('Contexts'));
      await tester.pumpAndSettle();
      await tester.tap(inMenu('Manage contexts…'));
      await tester.pumpAndSettle();
      expect(find.byType(WorkspacesDialog), findsOneWidget);
    });

    testWidgets('a chip offers the same menu on a right-click', (tester) async {
      seed(machines: false);
      await pump(tester);

      await tester.tap(chip('Game dev'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      for (final label in [
        'Show only Game dev',
        'Rename or describe…',
        'New context…',
        'Manage contexts…',
        'Delete context…',
      ]) {
        expect(inMenu(label), findsOneWidget, reason: label);
      }
    });
  });

  group('the list itself', () {
    testWidgets('a header is pinned while its rows pass under it, then pushed '
        'out by the next', (tester) async {
      seed(machines: false);
      for (var i = 0; i < 40; i++) {
        ProjectDao(db).insert(
          project(
            id: 'c$i',
            name: 'client-$i',
            path: '/c/$i',
            workspaceId: 'w1',
          ),
        );
        ProjectDao(
          db,
        ).insert(project(id: 'l$i', name: 'loose-$i', path: '/l/$i'));
      }
      await pump(tester, size: const Size(420, 600));
      final top = tester.getTopLeft(find.byType(ListView)).dy;
      Finder pinned(String label) => find.descendant(
        of: find.byType(ExplorerPinnedHeader),
        matching: find.text(label),
      );
      expect(pinned('CLIENT WORK'), findsNothing, reason: 'it is on screen');

      await tester.drag(find.byType(ListView), const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(find.text('proc-nepal'), findsNothing, reason: 'scrolled away');
      expect(
        tester.getTopLeft(pinned('CLIENT WORK')).dy,
        greaterThanOrEqualTo(top),
      );
      expect(
        tester
            .getRect(
              find.descendant(
                of: find.byType(ExplorerPinnedHeader),
                matching: find.byType(ExplorerContextHeader),
              ),
            )
            .top,
        moreOrLessEquals(top, epsilon: 0.5),
        reason: 'pinned to the top of the list',
      );

      // Its menu and its fold work from up there as they do in the list.
      await tester.tap(pinned('CLIENT WORK'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(inMenu('Show only Client work'), findsOneWidget);
      await tester.tapAt(const Offset(400, 590));
      await tester.pumpAndSettle();

      // Scrolled until the next header arrives under it: pushed, not stacked.
      await tester.scrollUntilVisible(
        find.text('GAME DEV'),
        120,
        scrollable: find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      final next = tester.getRect(find.text('GAME DEV').first);
      // Moved by exactly that much: a drag spends some of it on touch slop.
      final position = tester
          .state<ScrollableState>(
            find.descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            ),
          )
          .position;
      position.jumpTo(position.pixels + next.top - (top + 14));
      await tester.pumpAndSettle();
      final pushed = tester.getRect(
        find.descendant(
          of: find.byType(ExplorerPinnedHeader),
          matching: find.byType(ExplorerContextHeader),
        ),
      );
      expect(pushed.top, lessThan(top), reason: 'pushed up by the next header');
      expect(
        pushed.bottom,
        lessThanOrEqualTo(tester.getRect(find.text('GAME DEV').first).top),
        reason: 'and never drawn over it',
      );

      await tester.drag(find.byType(ListView), const Offset(0, -5000));
      await tester.pumpAndSettle();
      expect(
        pinned('CLIENT WORK'),
        findsNothing,
        reason: 'its group ended, so it left with it',
      );
      expect(pinned('NO CONTEXT'), findsOneWidget);
    });

    testWidgets('a row the keyboard reaches is not left under the pinned '
        'header', (tester) async {
      seed(machines: false);
      for (var i = 0; i < 40; i++) {
        ProjectDao(db).insert(
          project(
            id: 'c$i',
            name: 'client-$i',
            path: '/c/$i',
            workspaceId: 'w1',
          ),
        );
      }
      await pump(tester, size: const Size(420, 600));
      await tester.drag(find.byType(ListView), const Offset(0, -400));
      await tester.pumpAndSettle();
      final header = find.descendant(
        of: find.byType(ExplorerPinnedHeader),
        matching: find.byType(ExplorerContextHeader),
      );
      // A row kept built just above the top edge, where Shift+Tab lands.
      final above = find
          .byType(ExplorerProjectRow, skipOffstage: false)
          .evaluate()
          .map((element) => element.widget as ExplorerProjectRow)
          .firstWhere(
            (row) =>
                tester.getRect(find.byWidget(row, skipOffstage: false)).bottom <
                tester.getRect(header).top,
          );
      final name = find.text(above.project.name, skipOffstage: false);

      Focus.of(tester.element(name)).requestFocus();
      await tester.pumpAndSettle();

      expect(
        tester.getRect(find.byWidget(above)).top,
        greaterThanOrEqualTo(tester.getRect(header).bottom - 0.5),
        reason: 'revealed at the top edge, which the header covers',
      );
    });

    testWidgets('only the rows on screen are built, under pinned headers too', (
      tester,
    ) async {
      seed(machines: false);
      for (var i = 0; i < 300; i++) {
        ProjectDao(db).insert(
          project(
            id: 'c$i',
            name: 'client-$i',
            path: '/c/$i',
            workspaceId: 'w1',
          ),
        );
      }
      await pump(tester, size: const Size(420, 600));

      expect(
        find.byType(ExplorerProjectRow).evaluate().length,
        lessThan(40),
        reason: 'a pinned header must not make its list build every row',
      );
    });

    testWidgets('a reveal opens the header above the project', (tester) async {
      seed(machines: false);
      final container = newContainer();
      container
          .read(settingsControllerProvider.notifier)
          .toggleExplorerNodeCollapsed(contextHeaderId('w2'));
      await pump(tester, container: container);
      expect(drawn(tester), isNot(contains('roguelike')));

      container.read(sessionContextProvider).reveal('p2');
      await tester.pumpAndSettle();

      expect(drawn(tester), contains('roguelike'));
    });

    testWidgets('Shift-click selects the range in the order drawn, across '
        'headers', (tester) async {
      seed(machines: false);
      final container = await pump(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
      await tester.tap(find.text('proc-nepal'));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
      await tester.tap(find.text('scratch'));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
      await tester.pumpAndSettle();

      expect(container.read(sessionSelectionProvider).ids, {'p1', 'p2', 'p3'});
    });

    testWidgets('a search lists what matched under its header, and nothing '
        'else', (tester) async {
      seed();
      await pump(tester);

      await tester.enterText(find.byType(TextField), 'rel');
      await tester.pumpAndSettle();

      expect(drawn(tester), ['CLIENT WORK', 'relay']);
    });

    for (final (width, scale) in [
      (200.0, 1.0),
      (200.0, 2.0),
      (240.0, 1.3),
      (240.0, 2.0),
    ]) {
      testWidgets('fits ${width.toInt()}px at ${scale}x, and no count sits '
          'under the scrollbar', (tester) async {
        seed();
        final container = newContainer();
        container
            .read(workspaceScopeProvider.notifier)
            .select(const WorkspaceScope.of('w1'));
        await pump(
          tester,
          size: Size(width, 900),
          textScale: scale,
          container: container,
        );
        expect(tester.takeException(), isNull);

        // The scrollbar is 8px and stands 2px off the edge.
        final lane = width - 10;
        for (final element in find.byType(ExplorerRowMeta).evaluate()) {
          expect(
            tester.getTopRight(find.byWidget(element.widget)).dx,
            lessThanOrEqualTo(lane),
            reason: '${(element.widget as ExplorerRowMeta).text} is under it',
          );
        }
      });
    }
  });
}
