import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'dart:io';

import 'package:karmashala_store/database.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';

import 'package:karmashala/src/features/git/application/changes_providers.dart';

import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala/src/features/sessions/presentation/new_session_dialog.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_data_server.dart';
import '../../support/workspace_mirror.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
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
  late FakeDataServer server;
  late DataClient data;

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

  setUp(() async {
    db = AppDatabase.memory();
    server = FakeDataServer()..mirrorInto(db);
    data = await server.connect();
    server.environmentRows.upsert(windowsEnv());
    server.projectRows
      ..insert(project(id: 'p1', name: 'Alpha', path: r'C:\src\alpha'))
      ..insert(project(id: 'p2', name: 'Beta', path: r'C:\src\beta'));
    server.repositoryRows
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
    server.installationRows.insert(agentInstallation());
  });
  tearDown(() => db.close());

  void deleteAllRepositories() {
    for (final checkout in server.repositoryRows.getAll()) {
      server.repositoryRows.delete(checkout.id);
    }
  }

  ProviderContainer containerFor({String? selected, String? plainFolder}) {
    final container = ProviderContainer(
      overrides: [
        // The dialog asks whether the destination is under git before it offers
        // a worktree, and [PlainFolders] is the only disk that can answer
        // "not a repository" rather than "could not look".
        dataClientProvider.overrideWithValue(data),
        ...fakeTerminalOverrides(
          database: db,
          gitFiles: plainFolder == null ? null : PlainFolders({plainFolder}),
        ),
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
                onPressed: () =>
                    NewSessionDialog.show(context, targetPaneId: targetPaneId),
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
      expect(tester.widget<FilledButton>(startButton()).onPressed, isNotNull);
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

      final started = mirroredServer(db).sessionRows.getByRepository('r2');
      expect(
        started,
        hasLength(1),
        reason: 'the session was created in the checkout the picker named',
      );
      expect(mirroredServer(db).sessionRows.getByRepository('r1'), isEmpty);
      expect(find.byType(NewSessionDialog), findsNothing);

      // Now — and only now — the app follows: a pane describing one checkout
      // beside panels describing another is the incoherence this avoids.
      expect(container.read(selectedRepositoryIdProvider), 'r2');
      expect(container.read(selectedProjectIdProvider), 'p2');
      expect(container.read(selectedSessionIdProvider), started.single.id);
    });

    testWidgets('a title typed here is the person\'s; the one it opens with '
        'leaves the naming to the agent', (tester) async {
      final container = containerFor(selected: 'r1');
      container.read(selectedProjectIdProvider.notifier).select('p1');
      await open(tester, container);
      await tester.tap(startButton());
      await tester.pumpAndSettle();
      final untouched = mirroredServer(db).sessionRows.getByRepository('r1');
      expect(untouched.single.title, 'New session');
      expect(untouched.single.titleByUser, isFalse);

      await open(tester, container);
      await tester.enterText(
        find.widgetWithText(TextField, 'Title'),
        'desktop 1c',
      );
      await tester.tap(startButton());
      await tester.pumpAndSettle();
      final typed = mirroredServer(db).sessionRows
          .getByRepository('r1')
          .singleWhere((s) => s.title != 'New session');
      expect(typed.title, 'desktop 1c');
      expect(
        typed.titleByUser,
        isTrue,
        reason: 'no agent title may replace a name the person typed',
      );
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

      expect(
        mirroredServer(db).sessionRows.getByRepository('wt1'),
        hasLength(1),
      );
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
    expect(
      mirroredServer(db).sessionRows.getByRepository('r1').single.paneId,
      agentPane,
    );
  });

  testWidgets('an external session opens in the first terminal found', (
    tester,
  ) async {
    const wezterm = SystemTerminal(
      kind: SystemTerminalKind.wezterm,
      label: 'WezTerm',
      executable: 'wezterm',
    );
    const alacritty = SystemTerminal(
      kind: SystemTerminalKind.alacritty,
      label: 'Alacritty',
      executable: 'alacritty',
    );
    late _RecordingLauncher launcher;
    final container = ProviderContainer(
      parent: containerFor(selected: 'r1'),
      overrides: [
        availableSystemTerminalsProvider.overrideWith(
          (ref) async => const [wezterm, alacritty],
        ),
        sessionLauncherProvider.overrideWith(
          (ref) => launcher = _RecordingLauncher(ref),
        ),
      ],
    );
    addTearDown(container.dispose);
    await open(tester, container);

    await tester.tap(find.text('External terminal'));
    await tester.pumpAndSettle();
    await tester.tap(startButton());
    await tester.pumpAndSettle();

    // Nothing picked, so the terminal the dropdown shows is the one used.
    expect(launcher.terminals, [wezterm]);
  });

  group('a workspace with nothing to run in', () {
    testWidgets('says so instead of offering an empty dropdown', (
      tester,
    ) async {
      server.projectRows
        ..delete('p1')
        ..delete('p2');
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

    /// **A project with no checkout is not a project with nowhere to run.**
    ///
    /// Reported as "starting a session in a project without git fails". Git is
    /// how checkouts are *discovered*, not what makes a directory runnable —
    /// every agent CLI starts in a plain folder — so the project's own folder
    /// is recorded and offered rather than refused.
    testWidgets('a project with no checkouts runs in its own folder', (
      tester,
    ) async {
      final folder = Directory.systemTemp.createTempSync('ks-no-git');
      addTearDown(() => folder.deleteSync(recursive: true));
      deleteAllRepositories();
      server.projectRows.update(
        project(id: 'p1', name: 'Alpha', path: folder.path),
      );

      final container = containerFor(plainFolder: folder.path);
      await open(tester, container);
      await tester.pumpAndSettle();

      expect(find.textContaining('nowhere recorded to run in'), findsNothing);
      expect(
        server.repositoryRows.getByProject('p1').single.path.path,
        folder.path,
      );
      expect(tester.widget<FilledButton>(startButton()).onPressed, isNotNull);
      // Absent, not broken: there is no repository to take a worktree from.
      expect(find.text('Run in a dedicated Git worktree'), findsNothing);
    });

    testWidgets('and one whose folder is gone says so, naming it', (
      tester,
    ) async {
      deleteAllRepositories();
      final container = containerFor();
      await open(tester, container);

      // The blanket "nowhere recorded" is replaced by the reason there really
      // is nowhere — a refusal the user can act on.
      expect(find.textContaining(r'C:\src\alpha'), findsOneWidget);
      expect(tester.widget<FilledButton>(startButton()).onPressed, isNull);
    });
  });
}

/// Records the terminal a launch was asked for, and launches nothing.
class _RecordingLauncher extends SessionLauncher {
  _RecordingLauncher(super.ref);

  final terminals = <SystemTerminal?>[];

  @override
  Future<SessionLaunchResult> launch(
    SessionLaunchRequest request, {
    SystemTerminal? externalTerminal,
  }) async {
    terminals.add(externalTerminal);
    throw StateError('recorded, not launched');
  }
}
