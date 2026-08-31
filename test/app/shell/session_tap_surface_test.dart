import 'dart:async';

import 'package:chitragupta/src/app/shell/workbench.dart';
import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/process/command_runner_providers.dart';
import 'package:chitragupta/src/core/util/clock_provider.dart';
import 'package:chitragupta/src/core/util/id_generator_provider.dart';
import 'package:chitragupta/src/features/agents/application/agent_providers.dart';
import 'package:chitragupta/src/features/agents/data/agent_installation_dao.dart';
import 'package:chitragupta/src/features/agents/domain/agent_descriptor.dart';
import 'package:chitragupta/src/features/agents/domain/agent_registry.dart';
import 'package:chitragupta/src/features/agents/domain/agent_status.dart';
import 'package:chitragupta/src/features/cli_detection/data/imported_session_dao.dart';
import 'package:chitragupta/src/features/cli_detection/domain/imported_session.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/explorer/application/explorer_actions.dart';
import 'package:chitragupta/src/features/projects/data/project_dao.dart';
import 'package:chitragupta/src/features/repositories/data/repository_dao.dart';
import 'package:chitragupta/src/features/sessions/application/delivery_providers.dart';
import 'package:chitragupta/src/features/sessions/application/session_status_providers.dart';
import 'package:chitragupta/src/features/sessions/application/session_ui_providers.dart';
import 'package:chitragupta/src/features/sessions/data/session_dao.dart';
import 'package:chitragupta/src/features/sessions/domain/session.dart';
import 'package:chitragupta/src/features/sessions/domain/session_delivery.dart';
import 'package:chitragupta/src/features/sessions/domain/session_status.dart';
import 'package:chitragupta/src/features/settings/application/settings_controller.dart';
import 'package:chitragupta/src/features/settings/domain/permission_mode.dart';
import 'package:chitragupta/src/features/settings/domain/settings.dart';
import 'package:chitragupta/src/features/terminal/application/system_terminal_providers.dart';
import 'package:chitragupta/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:chitragupta/src/features/terminal/data/system_terminal_service.dart';
import 'package:chitragupta/src/features/terminal/domain/pane_liveness.dart';
import 'package:chitragupta/src/features/terminal/domain/terminal_profile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../features/terminal/fake_instance.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// **What the owner does**, not what a unit test does.
///
/// Every test here mounts the real workbench, then calls the real
/// [ExplorerActions] the Explorer row's `onTap` calls, and reads the surface on
/// **every frame** from the tap until the action has settled. The previous
/// attempt at this bug was proved by making a pane appear by hand, one
/// `pump()` after a selection, which is not a tap: it skipped the selection
/// order, the resume, and — the thing that actually shipped the bug — the
/// asynchronous gap in the middle of one.
///
/// The rule under test is the owner's, and it is stronger than "it settles on
/// the terminal": a tap on a session row must never put the chat surface on
/// screen, not even for one frame.

class _StaticSettings extends SettingsController {
  @override
  Settings build() => const Settings();
}

/// An agent that can be resumed, so a tap on a stopped row actually launches.
const _resumable = AgentDescriptor(
  id: 'resumable',
  displayName: 'Resumable Agent',
  binaries: AgentBinaries(windows: ['resumable'], posix: ['resumable']),
  launch: AgentLaunchSpec(
    permissionModes: {
      PermissionMode.ask: PermissionModeMapping.exact(['--ask']),
    },
    interactiveResume: AgentResume.flag('--resume'),
    allowsConcurrentResume: true,
  ),
);

void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation(agentId: 'resumable'));
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('s-')),
        agentRegistryProvider.overrideWithValue(
          const AgentRegistry([_resumable]),
        ),
        settingsControllerProvider.overrideWith(_StaticSettings.new),
        hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(),
        ),
        // Everything below polls a real timer or a real host, which a widget
        // test must never do; none of it is what these tests are about.
        sessionTranscriptProvider.overrideWith((ref) => Stream.value(const [])),
        importedTranscriptProvider.overrideWith(
          (ref, _) => Stream.value(const []),
        ),
        availableSystemTerminalsProvider.overrideWith(
          (ref) async => const <SystemTerminal>[],
        ),
        sessionDeliveryProvider.overrideWith(
          (ref, _) async => SessionDelivery.unknown,
        ),
        agentSessionStatusProvider.overrideWith(
          (ref, id) => const Stream<AgentStatusReport>.empty(),
        ),
      ],
    );
    addTearDown(container.dispose);
  });
  tearDown(() => db.close());

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: WorkbenchView())),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Which surface is painted right now: `'terminal'` or `'chat'`.
  ///
  /// With nothing selected there is only one surface and no switcher, which is
  /// the terminal by construction.
  String surface(WidgetTester tester) {
    final stack = find.byKey(kWorkbenchSurfaces);
    if (stack.evaluate().isEmpty) return 'terminal';
    return tester.widget<IndexedStack>(stack).index == 0 ? 'terminal' : 'chat';
  }

  /// Runs [tap] and returns the surface on every frame it produces, starting
  /// with the state the tap's own synchronous work left behind.
  ///
  /// The action is deliberately **not** awaited before the pumping starts: a
  /// resume suspends on real work in the middle, and the frames painted during
  /// that suspension are the ones the user sees.
  Future<List<String>> framesDuring(
    WidgetTester tester,
    Future<void> Function() tap, {
    int frames = 20,
  }) async {
    var done = false;
    // Not awaited: the frames painted while the action is suspended are the
    // ones this is about. Errors are re-thrown after the sampling.
    Object? failure;
    unawaited(
      tap().then(
        (_) => done = true,
        onError: (Object e) {
          failure = e;
          done = true;
        },
      ),
    );
    final seen = <String>[];
    for (var i = 0; i < frames && !done; i++) {
      await tester.pump();
      seen.add(surface(tester));
      // A resume reads the CLI's own store, which is real I/O: `runAsync` lets
      // it complete, and the next `pump` flushes the continuations it queued
      // back into the test's zone. Without both halves the action never ends.
      if (!done)
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    }
    await tester.pumpAndSettle();
    seen.add(surface(tester));
    if (failure != null) throw failure!;
    return seen;
  }

  Session stopped({String id = 'old', String externalId = 'ext-1'}) => Session(
    id: id,
    repositoryId: 'r1',
    agentInstallationId: 'a1',
    title: 'Earlier work',
    useWorktree: false,
    status: SessionStatus.completed,
    createdAt: testTime,
    externalSessionId: externalId,
  );

  ImportedSession imported({String id = 'i1', String externalId = 'ext-9'}) =>
      ImportedSession(
        id: id,
        repositoryId: 'r1',
        cli: 'resumable',
        externalId: externalId,
        environmentId: 'windows',
        filePath: r'C:\nope\never-read.jsonl',
        storeHome: r'C:\nope',
        isSubagent: false,
        preview: 'an earlier conversation',
        createdAt: testTime,
      );

  testWidgets('(a) a native session with no live pane never shows chat', (
    tester,
  ) async {
    SessionDao(db).insert(stopped());
    await mount(tester);

    final seen = await framesDuring(
      tester,
      () => container.read(explorerActionsProvider).openNative('old'),
    );

    expect(seen, everyElement('terminal'), reason: 'frames were: $seen');
    expect(container.read(terminalVisibleProvider), isTrue);
  });

  testWidgets('(b) a native session with a dormant pane never shows chat', (
    tester,
  ) async {
    // The shape a restored workspace leaves: the pane is still there and still
    // holds the session's scrollback, but nothing is running in it. `reveal`
    // refuses it (it wants `isLive`) while the workbench will happily show it,
    // so the tap both shows a terminal and resumes into another one.
    final terminals = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    terminals.openTab(TerminalProfile.powerShell);
    final paneId = container
        .read(terminalSessionsControllerProvider)
        .activeTab!
        .layout
        .panes
        .single;
    (terminals.instanceFor(paneId)! as FakeTerminalInstance)
            .livenessNotifier
            .value =
        PaneLiveness.exited;
    SessionDao(db)
      ..insert(stopped())
      ..updatePaneId('old', paneId);
    await mount(tester);

    final seen = await framesDuring(
      tester,
      () => container.read(explorerActionsProvider).openNative('old'),
    );

    expect(seen, everyElement('terminal'), reason: 'frames were: $seen');
    expect(container.read(terminalVisibleProvider), isTrue);
  });

  testWidgets('(c) an imported session never shows chat', (tester) async {
    ImportedSessionDao(db).insertIfAbsent(imported());
    await mount(tester);

    final seen = await framesDuring(
      tester,
      () => container.read(explorerActionsProvider).openImported(imported()),
    );

    expect(seen, everyElement('terminal'), reason: 'frames were: $seen');
    expect(container.read(terminalVisibleProvider), isTrue);
  });

  testWidgets('(d) a tap that cannot resume anything still shows no chat', (
    tester,
  ) async {
    // The deterministic half of the bug, and the one no correction could ever
    // undo: the CLI never told us this conversation's id, so `openNative`
    // selects the row and starts nothing. Under the old rule that was a
    // permanent landing on the chat interface.
    SessionDao(db).insert(stopped(externalId: ''));
    await mount(tester);

    final seen = await framesDuring(
      tester,
      () => container.read(explorerActionsProvider).openNative('old'),
    );

    expect(seen, everyElement('terminal'), reason: 'frames were: $seen');
    // ...and the terminal it lands on says what is true, rather than showing
    // whatever tab happened to be up.
    expect(
      find.textContaining('never learned the conversation'),
      findsOneWidget,
    );
    expect(find.text('Resume in a terminal'), findsNothing);
  });

  testWidgets('chat is still one labelled tap away', (tester) async {
    // The fix must not be "chat is unreachable". Nothing *lands* there; the
    // toggle still goes there, and stays there.
    SessionDao(db).insert(stopped());
    await mount(tester);
    await framesDuring(
      tester,
      () => container.read(explorerActionsProvider).openNative('old'),
    );

    await tester.tap(find.byTooltip('Chat view'));
    await tester.pumpAndSettle();
    expect(surface(tester), 'chat');

    // A revision bump — the app publishes them constantly — must not throw the
    // user back to the terminal.
    container.read(sessionsRevisionProvider.notifier).bump();
    await tester.pumpAndSettle();
    expect(surface(tester), 'chat');
  });
}
