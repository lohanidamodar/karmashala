import 'package:karmashala_store/database.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:flutter/gestures.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/agents/presentation/usage_chip.dart'
    show formatResetClock;
import 'package:karmashala/src/features/automations/application/automation_providers.dart';
import 'package:karmashala/src/features/automations/application/scheduled_resume_providers.dart';
import 'package:karmashala/src/features/automations/domain/scheduled_resume.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_service.dart';
import 'package:karmashala/src/features/cli_detection/application/project_import_service.dart';
import 'package:karmashala/src/features/cli_detection/data/imported_session_dao.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_signals.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_cli_store_locator.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// **A session's own tick repaints that session's row, not the Explorer.**
///
/// Identity is the probe, as in `explorer_rebuild_triggers_test.dart`: a
/// rebuilt widget is a new instance. The panel's [PaneScaffold] stands for the
/// panel, and every other [SessionCard] for the siblings.
class _PinnedSettings extends SettingsController {
  @override
  // n0 is pinned so its liveness cannot move it in the sort: a reorder is a
  // legitimate tree rebuild, and this file measures the ticks that are not.
  Settings build() => const Settings(pinnedSessionIds: ['n0']);
}

class _NoStores implements CliDetectionService {
  const _NoStores();
  @override
  Future<List<DetectedProject>> detect(
    List<CliStore> stores,
    Map<String, ExecutionEnvironment> environmentsById,
  ) async => const [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project(id: 'p1', name: 'Hub', path: r'C:\hub'));
    RepositoryDao(
      db,
    ).insert(repository(id: 'r1', name: 'hub', path: r'C:\hub'));
    AgentInstallationDao(db).insert(agentInstallation());
    for (var i = 0; i < 6; i++) {
      SessionDao(db).insert(
        Session(
          id: 'n$i',
          repositoryId: 'r1',
          agentInstallationId: 'a1',
          title: 'Native $i',
          useWorktree: false,
          status: SessionStatus.completed,
          createdAt: testTime.add(Duration(minutes: i)),
          externalSessionId: 'native-ext-$i',
        ),
      );
    }
    for (var i = 0; i < 6; i++) {
      ImportedSessionDao(db).insertIfAbsent(
        ImportedSession(
          id: 'i$i',
          repositoryId: 'r1',
          cli: 'claudeCode',
          externalId: 'imported-ext-$i',
          environmentId: 'windows',
          filePath: 'C:\\store\\imported-ext-$i.jsonl',
          storeHome: r'C:\store',
          isSubagent: false,
          preview: 'Imported $i',
          title: 'Imported $i',
          updatedAt: testTime.add(Duration(minutes: i)),
          createdAt: testTime,
        ),
      );
    }
  });
  tearDown(() => db.close());

  Future<({ProviderContainer container, FakeTerminalInstance pane})> pump(
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(460, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('n-')),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(
            fallback: FakeCommandRunner(
              responder: (_) =>
                  const CommandResult(exitCode: 0, stdout: '', stderr: ''),
            ),
          ),
        ),
        availableSystemTerminalsProvider.overrideWith(
          (ref) async => const <SystemTerminal>[],
        ),
        cliStoreLocatorProvider.overrideWithValue(FixedLocator(const [])),
        autoImportRunnerProvider.overrideWithValue(
          (_) async => const ImportSummary(),
        ),
        settingsControllerProvider.overrideWith(_PinnedSettings.new),
        cliDetectionServiceProvider.overrideWithValue(const _NoStores()),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: ExplorerPanel())),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hub'));
    await tester.pumpAndSettle();

    final terminals = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    final tabId = terminals.openTab(
      TerminalProfile.powerShell,
      workingDirectory: r'C:\hub',
    );
    final paneId = container
        .read(terminalSessionsControllerProvider)
        .tabs
        .firstWhere((tab) => tab.id == tabId)
        .focusedPaneId;
    SessionDao(db).updatePaneId('n0', paneId);
    container
        .read(sessionsRevisionProvider.notifier)
        .changed(SessionChange.moved('n0'));
    await tester.pumpAndSettle();
    return (
      container: container,
      pane: terminals.instanceFor(paneId)! as FakeTerminalInstance,
    );
  }

  Map<String, int> cards(WidgetTester tester) => {
    for (final card in tester.widgetList<SessionCard>(find.byType(SessionCard)))
      card.title: identityHashCode(card),
  };

  int panel(WidgetTester tester) =>
      identityHashCode(tester.widget(find.byType(PaneScaffold)));

  List<String> rebuilt(Map<String, int> before, Map<String, int> after) => [
    for (final entry in after.entries)
      if (before[entry.key] != entry.value) entry.key,
  ];

  testWidgets('a status change rebuilds that row and nothing else', (
    tester,
  ) async {
    final harness = await pump(tester);
    final before = cards(tester);
    final panelBefore = panel(tester);
    expect(before.length, 12, reason: 'every card must be on screen to count');

    SessionDao(db).updateStatus('n3', SessionStatus.idle);
    harness.container
        .read(sessionsRevisionProvider.notifier)
        .changed(SessionChange.statusChanged('n3'));
    await tester.pump();

    expect(panel(tester), panelBefore, reason: 'the panel must not rebuild');
    expect(rebuilt(before, cards(tester)), ['Native 3']);
    // The control: the one row that did rebuild drew the new status.
    final label = tester
        .widgetList<SessionCard>(find.byType(SessionCard))
        .firstWhere((card) => card.title == 'Native 3')
        .agentLabel;
    expect(label, contains(SessionStatus.idle.labelWhen(hostedLive: false)));
  });

  testWidgets('a pane exiting rebuilds neither the panel nor a sibling row', (
    tester,
  ) async {
    final harness = await pump(tester);
    final before = cards(tester);
    final panelBefore = panel(tester);

    harness.pane.exitWith(1);
    await tester.pump();

    expect(panel(tester), panelBefore, reason: 'the panel must not rebuild');
    expect(
      rebuilt(before, cards(tester)).where((title) => title != 'Native 0'),
      isEmpty,
    );
  });

  group('a scheduled resume', () {
    ScheduledResume arm(ProviderContainer container, String sessionId) {
      SessionDao(db).updatePermissionMode(sessionId, 'mode=bypassPermissions');
      return container
          .read(scheduledResumeControllerProvider)
          .schedule(
            ResumeRequest(
              sessionId: sessionId,
              fireAt: testTime.add(const Duration(hours: 2)),
            ),
          );
    }

    testWidgets('arming one rebuilds that row and nothing else, and the row '
        'says when', (tester) async {
      final harness = await pump(tester);
      final before = cards(tester);
      final panelBefore = panel(tester);

      final resume = arm(harness.container, 'n2');
      await tester.pump();

      expect(panel(tester), panelBefore, reason: 'the panel must not rebuild');
      expect(rebuilt(before, cards(tester)), ['Native 2']);
      final card = tester
          .widgetList<SessionCard>(find.byType(SessionCard))
          .firstWhere((card) => card.title == 'Native 2');
      expect(
        card.scheduled,
        'resumes ${formatResetClock(resume.fireAt, testTime.toLocal())}',
      );
      expect(card.scheduledTooltip, contains('sends "continue"'));
    });

    testWidgets('a write elsewhere in automations rebuilds no row', (
      tester,
    ) async {
      final harness = await pump(tester);
      arm(harness.container, 'n2');
      await tester.pump();
      final before = cards(tester);

      // The revision the badge shares with every automation and run.
      harness.container.read(automationsRevisionProvider.notifier).bump();
      await tester.pump();
      // And time passing: the row draws a clock time, which does not tick.
      await tester.pump(const Duration(minutes: 5));

      expect(rebuilt(before, cards(tester)), isEmpty);
    });

    testWidgets('its row menu changes or cancels it, and cancelling clears '
        'the row', (tester) async {
      final harness = await pump(tester);
      arm(harness.container, 'n2');
      await tester.pump();

      await tester.tap(find.text('Native 2'), buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      expect(find.text('Change scheduled resume…'), findsOneWidget);
      expect(find.text('Resume when usage resets…'), findsNothing);
      await tester.tap(find.text('Cancel scheduled resume'));
      await tester.pumpAndSettle();

      expect(
        harness.container.read(scheduledResumeDaoProvider).liveFor('n2'),
        isNull,
      );
      final card = tester
          .widgetList<SessionCard>(find.byType(SessionCard))
          .firstWhere((card) => card.title == 'Native 2');
      expect(card.scheduled, isNull);

      await tester.tap(find.text('Native 3'), buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      expect(find.text('Resume when usage resets…'), findsOneWidget);
    });
  });
}
