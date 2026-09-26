import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/app/karmashala_app.dart';
import 'package:karmashala/src/app/shell/side_panel_state.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/project_import_service.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/explorer/application/explorer_actions.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/media/application/session_media_providers.dart';
import 'package:karmashala/src/features/media/domain/session_media_item.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../features/terminal/fake_instance.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';
import '../../support/workspace_mirror.dart';

/// **An idle app draws nothing.**
///
/// Twelve seconds of the engine's own timeline, taken while the owner's window
/// sat idle with live sessions in it, counted 516 `VsyncFireCallback`s, 516
/// rasterizer draws and 516 glyph-atlas builds — ~43 fps of full GPU work with
/// nothing happening, and the 87-120% of a core the app burned overnight
/// (`docs/MEMORY-2026-09-20.md`, 2026-09-21).
///
/// The driver was an indeterminate spinner. Material's
/// `CircularProgressIndicator` drives an `AnimationController.repeat()` on a
/// vsync `Ticker`, so one spinner anywhere on screen asks for the next frame
/// the instant the current one is drawn, and every one of those frames is a
/// whole pipeline pass over the whole tree. Proven in this harness with
/// `debugAssertNoTransientCallbacks`, which named
/// `_CircularProgressIndicatorState.initState -> AnimationController.repeat ->
/// Ticker.scheduleTick` as the one outstanding scheduler callback.
///
/// What replaced it is in `packages/karmashala_ui`: [InlineSpinner] steps on
/// the shared [StatusSpinnerClock], one timer for every spinner in the app,
/// running only while a spinner is actually painting.
void main() {
  late AppDatabase db;
  late ProviderContainer container;

  /// Set before the container is built, so a case can decide whether the Media
  /// panel has an answer or is still waiting for one.
  late Stream<List<SessionMediaItem>> media;

  setUp(() async {
    db = AppDatabase.memory();
    final server = FakeDataServer()..mirrorInto(db);
    media = Stream.value(const []);
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
    for (final id in ['s1', 's2']) {
      SessionDao(db).insert(
        Session(
          id: id,
          repositoryId: 'r1',
          agentInstallationId: 'a1',
          title: 'Session $id',
          useWorktree: false,
          status: SessionStatus.running,
          createdAt: testTime,
          externalSessionId: 'ext-$id',
        ),
      );
    }
    final git = FakeCommandRunner();
    final data = await server.override();
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        data,
        clockProvider.overrideWithValue(FixedClock(testTime)),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: git),
        ),
        hostCommandRunnerProvider.overrideWithValue(git),
        sessionChatTranscriptProvider.overrideWith(
          (ref, sessionId) => Stream.value(const <TranscriptMessage>[]),
        ),
        availableSystemTerminalsProvider.overrideWith(
          (ref) async => const <SystemTerminal>[],
        ),
        autoImportRunnerProvider.overrideWithValue(
          (_) async => const ImportSummary(),
        ),
        // Idle, deliberately: a working session draws the status spinner, and
        // that one is *meant* to ask for its twelve frames a second.
        agentSessionStatusProvider.overrideWith(
          (ref, id) => Stream.value(
            AgentStatusReport(
              agentId: AgentIds.claudeCode,
              sessionId: id,
              status: AgentActivityStatus.idle,
              source: AgentStatusSource.hook,
              observedAt: testTime,
            ),
          ),
        ),
        sessionTranscriptProvider.overrideWith(
          (ref, id) => Stream.value(const []),
        ),
        importedTranscriptProvider.overrideWith(
          (ref, _) => Stream.value(const []),
        ),
        sessionMediaProvider.overrideWith((ref, id) => media),
      ],
    );
    addTearDown(container.dispose);
  });
  tearDown(() => db.close());

  Future<void> settle(WidgetTester tester, {int frames = 40}) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  /// The whole app, two live sessions with a pane each, one of them open.
  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    final controller = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    for (final id in ['s1', 's2']) {
      controller.openTab(TerminalProfile.powerShell);
      final paneId = container
          .read(terminalSessionsControllerProvider)
          .activeTab!
          .layout
          .panes
          .single;
      SessionDao(db).updatePaneId(id, paneId);
    }
    container.read(selectedRepositoryIdProvider.notifier).select('r1');

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const KarmashalaApp(),
      ),
    );
    await settle(tester);
    await tester.tap(find.text('Demo'));
    await settle(tester);
    await container.read(explorerActionsProvider).openNative('s1');
    await settle(tester);
  }

  testWidgets('with nothing in flight the shell schedules no frames', (
    tester,
  ) async {
    await mount(tester);

    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(StatusSpinnerClock.instance.isRunning, isFalse);
    // A whole second of wall clock with no frame asked for. An app that draws
    // while nobody is looking at it is the defect this file is about.
    await tester.binding.delayed(const Duration(seconds: 1));
    expect(
      tester.binding.hasScheduledFrame,
      isFalse,
      reason: 'an idle app draws nothing',
    );
  });

  testWidgets('a panel still waiting costs twelve frames a second, not sixty', (
    tester,
  ) async {
    // The Media panel with a source that has not answered yet: an honest
    // spinner, which must keep turning — the fix is what it costs, not
    // whether it is there.
    media = const Stream<List<SessionMediaItem>>.empty();
    await mount(tester);
    container.read(sidePanelProvider.notifier).select(SidePanelSurface.media);
    await settle(tester);

    expect(find.byType(InlineSpinner), findsOneWidget);

    await tester.pump();
    expect(
      tester.binding.hasScheduledFrame,
      isFalse,
      reason:
          'a drawn frame must not already owe the next one — a vsync ticker '
          'here is what put the idle window at ~43 fps',
    );
    await tester.binding.delayed(Motion.statusPeriod ~/ Motion.statusSteps);
    expect(
      tester.binding.hasScheduledFrame,
      isTrue,
      reason: 'and it is still a spinner',
    );
    expect(StatusSpinnerClock.instance.isRunning, isTrue);
  });
}
