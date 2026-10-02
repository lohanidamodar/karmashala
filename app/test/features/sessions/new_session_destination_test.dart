import 'dart:async';
import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';

import 'package:karmashala/src/features/git/application/changes_providers.dart';

import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala/src/features/sessions/presentation/new_session_dialog.dart';
import 'package:karmashala/src/features/sessions/presentation/slow_start_note.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:agent_cli/usage.dart';
import 'package:flutter/material.dart';
import 'package:karmashala/src/features/agents/application/agent_usage_providers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_git/git.dart' show GitPresence;
import 'package:karmashala_git/repositories.dart';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show
        AcpAuthMethod,
        AcpAuthMethods,
        DataRefusalCode,
        DataRefused,
        ScratchCheckoutCreate;
import 'package:karmashala_projects/karmashala_projects.dart' show Project;

import '../../support/fake_data_server.dart';
import '../../support/test_machine.dart';
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
  late TestMachine db;
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
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
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

  void deleteAllRepositories() {
    for (final checkout in server.repositoryRows.getAll()) {
      server.repositoryRows.delete(checkout.id);
    }
  }

  ProviderContainer containerFor({String? selected, String? plainFolder}) {
    // The dialog asks the server whether the destination is under git before
    // it offers a worktree; a plain folder answers "not a repository".
    if (plainFolder != null) {
      server.gitWork.presences[Checkout(
            EnvironmentPath(environmentId: 'windows', path: plainFolder),
          )] =
          GitPresence.notARepository;
    }
    // The picker classifies worktrees from `git worktree list`, at the server.
    server.gitWork.runner = FakeCommandRunner(responder: worktrees);
    final container = ProviderContainer(
      overrides: [
        dataClientProvider.overrideWithValue(data),
        // The agent cards read each account's usage; here it stays unread.
        agentUsageProvider.overrideWith(
          (ref, installation) => const AsyncLoading<AgentUsage>(),
        ),
        ...fakeTerminalOverrides(machine: db),
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

  /// Unmounts the dialog inside the test, so the dispose Riverpod schedules
  /// for the agent cards' usage lines runs before the pending-timer check.
  Future<void> closeAll(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    // Each dispose can release another provider, which schedules its own.
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 1));
  }

  group('it opens where the app is already pointed', () {
    testWidgets('at the selected checkout', (tester) async {
      final container = containerFor(selected: 'r1');
      await open(tester, container);

      expect(find.text('Alpha'), findsOneWidget);
      expect(find.textContaining('alpha-app'), findsOneWidget);
      expect(find.textContaining('beta-app'), findsNothing);
    });

    testWidgets('offering no card for an agent the registry has forgotten', (
      tester,
    ) async {
      // A removed ACP agent's leftover installation row: no name to show.
      server.installationRows.insert(
        agentInstallation(
          id: 'ghost',
          agentId: 'acp:gone',
          path: r'C:\gone\agent.exe',
        ),
      );
      final container = containerFor(selected: 'r1');
      await open(tester, container);

      expect(find.byKey(const ValueKey('agent-card:a1')), findsOneWidget);
      expect(find.byKey(const ValueKey('agent-card:ghost')), findsNothing);
      expect(find.text('acp:gone'), findsNothing);
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

      final started = db.server.sessionRows.getByRepository('r2');
      expect(
        started,
        hasLength(1),
        reason: 'the session was created in the checkout the picker named',
      );
      expect(db.server.sessionRows.getByRepository('r1'), isEmpty);
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
      final untouched = db.server.sessionRows.getByRepository('r1');
      expect(untouched.single.title, 'New session');
      expect(untouched.single.titleByUser, isFalse);

      await open(tester, container);
      await tester.enterText(
        find.widgetWithText(TextField, 'Title'),
        'desktop 1c',
      );
      await tester.tap(startButton());
      await tester.pumpAndSettle();
      final typed = db.server.sessionRows
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

      expect(db.server.sessionRows.getByRepository('wt1'), hasLength(1));
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
      db.server.sessionRows.getByRepository('r1').single.paneId,
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

    // The dialog scrolls as one: the agent cards and the first message put
    // these below the fold of the test's window.
    await tester.ensureVisible(find.text('External terminal'));
    await tester.tap(find.text('External terminal'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(startButton());
    await tester.tap(startButton());
    await tester.pumpAndSettle();

    // Nothing picked, so the terminal the dropdown shows is the one used.
    expect(launcher.terminals, [wezterm]);
    await closeAll(tester);
  });

  group('a workspace with nothing to run in', () {
    testWidgets('opens on No project, and can start there', (tester) async {
      server.projectRows
        ..delete('p1')
        ..delete('p2');
      final container = containerFor();
      await open(tester, container);

      // A workspace with no projects is not a workspace with nowhere to go:
      // a session without a project needs none.
      expect(find.text('No project'), findsOneWidget);
      expect(
        find.textContaining(
          'Runs in its own folder under ~/karmashala/scratch',
        ),
        findsOneWidget,
      );
      expect(find.text('Checkout'), findsNothing);
      expect(tester.widget<FilledButton>(startButton()).onPressed, isNotNull);
      await closeAll(tester);
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
  group('without a project', () {
    testWidgets('No project is the first pick, and needs no checkout', (
      tester,
    ) async {
      final container = containerFor(selected: 'r1');
      await open(tester, container);
      await choose(
        tester,
        current: find.text('Alpha'),
        option: find.text('No project'),
      );

      expect(find.text('Checkout'), findsNothing);
      expect(
        find.textContaining(
          'Runs in its own folder under ~/karmashala/scratch',
        ),
        findsOneWidget,
      );
      // Where a session runs is still the agent's machine, so every agent is
      // offered and Start is live.
      expect(tester.widget<FilledButton>(startButton()).onPressed, isNotNull);
      await closeAll(tester);
    });

    testWidgets('Start makes the scratch folder on the agent\'s machine, named '
        'after the first message, and launches there', (tester) async {
      // The server's answer: the folder it made, recorded under Scratch.
      server.gitWork.answer = (request) {
        if (request is! ScratchCheckoutCreate) return FakeGitWork.unhandled;
        server.projectRows.insert(
          project(
            id: 'ps',
            name: 'Scratch',
            path: r'C:\Users\me\karmashala\scratch',
            kind: Project.scratchKind,
          ),
        );
        final folder = repository(
          id: 'rs',
          projectId: 'ps',
          name: '2026-09-27-tidy-the-downloads-a1b2c3',
          path:
              r'C:\Users\me\karmashala\scratch\2026-09-27-tidy-the-downloads-a1b2c3',
        );
        server.repositoryRows.insert(folder);
        return folder;
      };
      final container = containerFor(selected: 'r1');
      await open(tester, container);
      await choose(
        tester,
        current: find.text('Alpha'),
        option: find.text('No project'),
      );
      final prompt = find.widgetWithText(TextField, 'First message (optional)');
      await tester.ensureVisible(prompt);
      await tester.enterText(prompt, 'Tidy the downloads');

      await tester.tap(startButton());
      await tester.pumpAndSettle();

      final asked = server.gitWork.asked.whereType<ScratchCheckoutCreate>();
      expect(asked.single.environmentId, 'windows');
      expect(asked.single.hint, 'Tidy the downloads');
      expect(db.server.sessionRows.getByRepository('rs'), hasLength(1));
      expect(find.byType(NewSessionDialog), findsNothing);
      expect(container.read(selectedProjectIdProvider), 'ps');
    });

    testWidgets('a folder the server cannot make is said, and nothing starts', (
      tester,
    ) async {
      final container = containerFor(selected: 'r1');
      await open(tester, container);
      await choose(
        tester,
        current: find.text('Alpha'),
        option: find.text('No project'),
      );

      await tester.tap(startButton());
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Could not make a scratch folder'),
        findsOneWidget,
      );
      expect(db.server.sessionRows.getAll(), isEmpty);
      await closeAll(tester);
    });
  });

  testWidgets('a first message goes with the launch, and Ctrl+Enter starts', (
    tester,
  ) async {
    late _RecordingLauncher launcher;
    final container = ProviderContainer(
      parent: containerFor(selected: 'r1'),
      overrides: [
        sessionLauncherProvider.overrideWith(
          (ref) => launcher = _RecordingLauncher(ref),
        ),
      ],
    );
    addTearDown(container.dispose);
    await open(tester, container);

    final prompt = find.widgetWithText(TextField, 'First message (optional)');
    await tester.ensureVisible(prompt);
    await tester.enterText(prompt, '  Add pagination to /trails  ');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(launcher.requests.single.firstMessage, 'Add pagination to /trails');
    await closeAll(tester);
  });

  testWidgets('a start that takes long says so under the spinner', (
    tester,
  ) async {
    // An agent run through npx is downloaded on its first start; a bare
    // spinner for minutes looked hung.
    final container = ProviderContainer(
      parent: containerFor(selected: 'r1'),
      overrides: [
        sessionLauncherProvider.overrideWith((ref) => _HoldingLauncher(ref)),
      ],
    );
    addTearDown(container.dispose);
    await open(tester, container);
    await tester.ensureVisible(startButton());
    await tester.tap(startButton());
    await tester.pump();
    expect(find.text(SlowStartNote.text), findsNothing);

    await tester.pump(kSlowStartAfter + const Duration(seconds: 1));
    expect(find.text(SlowStartNote.text), findsOneWidget);
    await closeAll(tester);
  });
  testWidgets('an agent that asks to be logged in first offers Log in, '
      'which lists its methods', (tester) async {
    server.agentWork.acpAuthMethods['a1'] = const AcpAuthMethods(
      installationId: 'a1',
      methods: [AcpAuthMethod(id: 'oauth', name: 'Log in with the browser')],
    );
    final container = ProviderContainer(
      parent: containerFor(selected: 'r1'),
      overrides: [
        sessionLauncherProvider.overrideWith((ref) => _LoginRequired(ref)),
      ],
    );
    addTearDown(container.dispose);
    await open(tester, container);
    expect(find.text('Log in…'), findsNothing);
    await tester.ensureVisible(startButton());
    await tester.tap(startButton());
    await tester.pumpAndSettle();

    expect(find.textContaining('asks to be logged in first'), findsOneWidget);
    await tester.ensureVisible(find.text('Log in…'));
    await tester.tap(find.text('Log in…'));
    await tester.pumpAndSettle();
    expect(find.text('Log in with the browser'), findsOneWidget);

    await tester.tap(find.text('Log in with the browser'));
    await tester.pumpAndSettle();
    expect(server.agentWork.acpAuthenticates, [('a1', 'oauth')]);
    expect(find.textContaining('asks to be logged in first'), findsNothing);
    expect(find.text('Logged in via Log in with the browser.'), findsOneWidget);
    await closeAll(tester);
  });
}

/// A start the server refused because the agent wants a login first.
class _LoginRequired extends SessionLauncher {
  _LoginRequired(super.ref);

  @override
  Future<SessionLaunchResult> launch(
    SessionLaunchRequest request, {
    SystemTerminal? externalTerminal,
  }) async => throw const DataRefused(
    DataRefusalCode.loginRequired,
    'Antigravity asks to be logged in first.',
  );
}

/// Records the terminal a launch was asked for, and launches nothing.
class _RecordingLauncher extends SessionLauncher {
  _RecordingLauncher(super.ref);

  final terminals = <SystemTerminal?>[];
  final requests = <SessionLaunchRequest>[];

  @override
  Future<SessionLaunchResult> launch(
    SessionLaunchRequest request, {
    SystemTerminal? externalTerminal,
  }) async {
    terminals.add(externalTerminal);
    requests.add(request);
    throw StateError('recorded, not launched');
  }
}

/// A launch that never comes back, as one waiting on an npx download.
class _HoldingLauncher extends SessionLauncher {
  _HoldingLauncher(super.ref);

  @override
  Future<SessionLaunchResult> launch(
    SessionLaunchRequest request, {
    SystemTerminal? externalTerminal,
  }) => Completer<SessionLaunchResult>().future;
}
