import 'package:karmashala_store/database.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/sessions/presentation/new_session_dialog.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// **Where a new session runs, chosen in the dialog that starts it.**
///
/// The report: *"opening a new session from the command prompt should allow
/// selecting a project"*. It could not — the dialog created a session for
/// whatever `selectedRepositoryIdProvider` happened to hold, so starting one
/// anywhere else meant going to the Explorer, moving the selection, coming
/// back, and finding the selection moved afterwards.
///
/// Two decisions are pinned here because they are decisions rather than
/// details:
///
/// * the dialog **opens on the current selection**, so the common case is
///   unchanged and costs no extra click;
/// * **browsing moves nothing and Start moves everything**. Choosing a
///   destination and cancelling leaves the app exactly as it was; pressing
///   Start makes the app follow the session it just created, because the pane
///   in front of you and the panels beside it must be describing the same
///   checkout.
void main() {
  late AppDatabase db;

  /// `git worktree list --porcelain` for the Alpha clone, so the picker can
  /// tell a worktree from a clone the way production does.
  CommandResult worktrees(CommandRequest request) {
    final args = request.arguments.join(' ');
    const nothing = CommandResult(exitCode: 0, stdout: '', stderr: '');
    if (!args.contains('worktree list')) return nothing;
    // `git -C <path> worktree list --porcelain`: only the Alpha clone has one.
    if (!args.contains('alpha')) return nothing;
    return const CommandResult(
      exitCode: 0,
      stderr: '',
      stdout:
          'worktree C:/src/alpha/app\n'
          'HEAD 1111111111111111111111111111111111111111\n'
          'branch refs/heads/main\n'
          '\n'
          'worktree C:/src/alpha/wt-login\n'
          'HEAD 2222222222222222222222222222222222222222\n'
          'branch refs/heads/login\n'
          '\n',
    );
  }

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db)
      ..insert(project(id: 'p1', name: 'Alpha', path: r'C:\src\alpha'))
      ..insert(project(id: 'p2', name: 'Beta', path: r'C:\src\beta'));
    RepositoryDao(db)
      ..insert(
        repository(
          id: 'r1',
          projectId: 'p1',
          name: 'alpha-app',
          path: r'C:\src\alpha\app',
        ),
      )
      ..insert(
        repository(
          id: 'wt1',
          projectId: 'p1',
          name: 'wt-login',
          path: r'C:\src\alpha\wt-login',
        ),
      )
      ..insert(
        repository(
          id: 'r2',
          projectId: 'p2',
          name: 'beta-app',
          path: r'C:\src\beta\app',
        ),
      );
    AgentInstallationDao(db).insert(agentInstallation());
  });
  tearDown(() => db.close());

  ProviderContainer containerFor({String? selected}) {
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        // Nothing here may shell out: the picker classifies worktrees from
        // `git worktree list`, and a real one would run against paths that do
        // not exist on the machine running the suite.
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(
            fallback: FakeCommandRunner(responder: worktrees),
          ),
        ),
        hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
      ],
    );
    addTearDown(container.dispose);
    if (selected != null) {
      container.read(selectedRepositoryIdProvider.notifier).select(selected);
    }
    return container;
  }

  /// Opens the dialog on a real route, so Cancel and Start can actually pop it.
  Future<void> open(
    WidgetTester tester,
    ProviderContainer container, {
    String? targetPaneId,
  }) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => NewSessionDialog.show(
                  context,
                  targetPaneId: targetPaneId,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  /// Opens the dropdown showing [current] and picks [option] out of it.
  Future<void> choose(
    WidgetTester tester, {
    required Finder current,
    required Finder option,
  }) async {
    await tester.tap(current.first);
    await tester.pumpAndSettle();
    // `.last`: the closed button still holds a copy of its own label, and the
    // menu is drawn over it.
    await tester.tap(option.last);
    await tester.pumpAndSettle();
  }

  Finder startButton() => find.widgetWithText(FilledButton, 'Start');

  group('it opens where the app is already pointed', () {
    testWidgets('at the selected checkout', (tester) async {
      final container = containerFor(selected: 'r1');
      await open(tester, container);

      expect(find.text('Alpha'), findsOneWidget);
      expect(find.textContaining('alpha-app'), findsOneWidget);
      expect(find.textContaining('beta-app'), findsNothing);
    });

    testWidgets('and at the first project when nothing is selected', (
      tester,
    ) async {
      final container = containerFor();
      await open(tester, container);

      // The command used to be hidden in this state. It is offered now, and
      // what it offers is a workspace that can still be started in.
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.textContaining('alpha-app'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(startButton()).onPressed,
        isNotNull,
      );
    });
  });

  group('choosing somewhere else', () {
    testWidgets('does not move the app under the user', (tester) async {
      final container = containerFor(selected: 'r1');
      container.read(selectedProjectIdProvider.notifier).select('p1');
      await open(tester, container);

      await choose(
        tester,
        current: find.text('Alpha'),
        option: find.text('Beta'),
      );
      expect(find.textContaining('beta-app'), findsOneWidget);

      expect(
        container.read(selectedRepositoryIdProvider),
        'r1',
        reason:
            'browsing for a destination is not the same as saying "I work '
            'here now"; the Explorer must not have moved',
      );
      expect(container.read(selectedProjectIdProvider), 'p1');
    });

    testWidgets('starts the session there, and the app follows', (
      tester,
    ) async {
      final container = containerFor(selected: 'r1');
      container.read(selectedProjectIdProvider.notifier).select('p1');
      await open(tester, container);
      await choose(
        tester,
        current: find.text('Alpha'),
        option: find.text('Beta'),
      );

      await tester.tap(startButton());
      await tester.pumpAndSettle();

      final started = SessionDao(db).getByRepository('r2');
      expect(
        started,
        hasLength(1),
        reason: 'the session was created in the checkout the picker named',
      );
      expect(SessionDao(db).getByRepository('r1'), isEmpty);
      expect(find.byType(NewSessionDialog), findsNothing);

      // Now — and only now — the app follows: a pane describing one checkout
      // beside panels describing another is the incoherence this avoids.
      expect(container.read(selectedRepositoryIdProvider), 'r2');
      expect(container.read(selectedProjectIdProvider), 'p2');
      expect(container.read(selectedSessionIdProvider), started.single.id);
    });

    testWidgets('and a worktree of the chosen checkout is a destination', (
      tester,
    ) async {
      final container = containerFor(selected: 'r1');
      await open(tester, container);

      // Level two: `wt-login` is a worktree of `alpha-app`, so it is offered
      // indented underneath it rather than as a clone of its own.
      await choose(
        tester,
        current: find.textContaining('alpha-app'),
        option: find.textContaining('wt-login'),
      );

      await tester.tap(startButton());
      await tester.pumpAndSettle();

      expect(SessionDao(db).getByRepository('wt1'), hasLength(1));
    });
  });

  testWidgets('an empty split receives the new in-app session', (tester) async {
    final container = containerFor(selected: 'r1');
    final terminals = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    final host = terminals.openTab(TerminalProfile.powerShell);
    final shellPane = container
        .read(terminalSessionsControllerProvider)
        .activeTab!
        .layout
        .panes
        .single;
    final slot = terminals.splitPane(SplitAxis.horizontal)!;
    await open(tester, container, targetPaneId: slot);

    await tester.tap(startButton());
    await tester.pumpAndSettle();

    final state = container.read(terminalSessionsControllerProvider);
    expect(state.tabs, hasLength(1), reason: 'no extra workbench tab is made');
    expect(state.activeTab!.id, host);
    expect(state.activeTab!.layout.panes, hasLength(2));
    expect(state.activeTab!.layout.panes, contains(shellPane));
    expect(state.activeTab!.layout.panes, isNot(contains(slot)));
    final agentPane = state.activeTab!.layout.panes.singleWhere(
      (paneId) => paneId != shellPane,
    );
    expect(terminals.instanceFor(agentPane)?.agentLaunch, isNotNull);
    expect(SessionDao(db).getByRepository('r1').single.paneId, agentPane);
  });

  group('a workspace with nothing to run in', () {
    testWidgets('says so instead of offering an empty dropdown', (
      tester,
    ) async {
      db.execute('DELETE FROM repositories;');
      db.execute('DELETE FROM projects;');
      final container = containerFor();
      await open(tester, container);

      expect(find.textContaining('no projects yet'), findsOneWidget);
      expect(find.text('Add project…'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(startButton()).onPressed,
        isNull,
        reason: 'there is nowhere to start it',
      );
    });

    testWidgets('and a project with no checkouts says that instead', (
      tester,
    ) async {
      db.execute('DELETE FROM repositories;');
      final container = containerFor();
      await open(tester, container);

      expect(
        find.textContaining('no Git repositories to run in'),
        findsOneWidget,
      );
      expect(tester.widget<FilledButton>(startButton()).onPressed, isNull);
    });
  });
}
