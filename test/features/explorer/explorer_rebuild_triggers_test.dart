import 'package:karmashala_store/database.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/project_import_service.dart';
import 'package:karmashala/src/features/cli_detection/data/imported_session_dao.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/notifications/application/session_status_registry.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:karmashala_terminal_runtime/instances.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:karmashala/src/features/cli_detection/application/cli_detection_service.dart';

import '../../support/fake_cli_store_locator.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// **What actually makes the Explorer rebuild.**
///
/// Flutter has one UI thread, so anything the Explorer does during a frame
/// delays the terminal's echo — but only if the Explorer rebuilds *while the
/// user is typing*. That is a measurement, not a deduction, and this file is
/// the measurement: a workspace the size of the owner's (7 native sessions,
/// 107 imported), a live pane, and a count of how many session cards are
/// rebuilt by each thing that happens in a terminal.
///
/// A rebuilt card is a **new widget instance** in the tree, so identity is the
/// counter: it needs no instrumentation inside the widgets under test and
/// cannot be fooled by a card that rebuilt to the same pixels.
class _StaticSettings extends SettingsController {
  @override
  Settings build() => const Settings();
}

/// A detection service with no stores behind it.
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

class _MovableClock implements Clock {
  _MovableClock(this.now);
  DateTime now;
  @override
  DateTime nowUtc() => now.toUtc();
}

void main() {
  late AppDatabase db;
  late _MovableClock clock;

  setUp(() {
    db = AppDatabase.memory();
    clock = _MovableClock(testTime);
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project(id: 'p1', name: 'Hub', path: r'C:\hub'));
    RepositoryDao(
      db,
    ).insert(repository(id: 'r1', name: 'hub', path: r'C:\hub'));
    AgentInstallationDao(db).insert(agentInstallation());
    // The owner's own database, as reported: 7 native, 107 imported.
    for (var i = 0; i < 7; i++) {
      SessionDao(db).insert(
        Session(
          id: 'n$i',
          repositoryId: 'r1',
          agentInstallationId: 'a1',
          title: 'Native $i',
          useWorktree: false,
          status: SessionStatus.running,
          createdAt: testTime.add(Duration(minutes: i)),
          externalSessionId: 'native-ext-$i',
        ),
      );
    }
    for (var i = 0; i < 107; i++) {
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

  /// The panel, the whole real provider graph behind it, and a live pane.
  ///
  /// `agentSessionStatusProvider` is deliberately **not** stubbed: the question
  /// is whether the real status pipeline reaches the Explorer, so the real
  /// registry has to be in the graph.
  Future<({ProviderContainer container, TerminalInstance pane})> pump(
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(460, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(clock),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('n-')),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(
            fallback: FakeCommandRunner(responder: _git),
          ),
        ),
        availableSystemTerminalsProvider.overrideWith(
          (ref) async => const <SystemTerminal>[],
        ),
        // No store to walk. Without this the registry's store slot reads the
        // machine's own `.claude`, so the test would be measuring the
        // developer's home directory.
        cliStoreLocatorProvider.overrideWithValue(FixedLocator(const [])),
        autoImportRunnerProvider.overrideWithValue(
          (_) async => const ImportSummary(),
        ),
        settingsControllerProvider.overrideWith(_StaticSettings.new),
        // The real registry and the real adoption service are wanted here; the
        // real *stores* are not. Without this the status pipeline walks the
        // machine's own ~/.claude on Windows, which is both slow and none of a
        // test's business.
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
    // Bind the pane to a session, so every per-session provider the cards read
    // has a live terminal behind it — the worst case for fan-out.
    SessionDao(db).updatePaneId('n0', paneId);
    await tester.pumpAndSettle();
    return (container: container, pane: terminals.instanceFor(paneId)!);
  }

  /// Identity of every session card on screen, so a rebuild is countable.
  List<int> cardIdentities(WidgetTester tester) => [
    for (final card in tester.widgetList<SessionCard>(find.byType(SessionCard)))
      identityHashCode(card),
  ];

  int changed(List<int> before, List<int> after) {
    if (before.length != after.length) return after.length;
    var count = 0;
    for (var i = 0; i < before.length; i++) {
      if (before[i] != after[i]) count++;
    }
    return count;
  }

  testWidgets('terminal output rebuilds no session card', (tester) async {
    final harness = await pump(tester);
    final before = cardIdentities(tester);
    expect(before, isNotEmpty, reason: 'the cards must be on screen to count');

    // A busy agent: a hundred writes, the way a build log arrives.
    for (var i = 0; i < 100; i++) {
      harness.pane.terminal.write('line $i of output\r\n');
    }
    await tester.pump();

    final after = cardIdentities(tester);
    // ignore: avoid_print
    print(
      'EXPLORER-TRIGGER output cards=${before.length} '
      'rebuilt=${changed(before, after)}',
    );
    expect(changed(before, after), 0);
  });

  testWidgets('keystrokes rebuild no session card', (tester) async {
    final harness = await pump(tester);
    final before = cardIdentities(tester);

    for (final key in 'flutter test --coverage'.split('')) {
      harness.pane.terminal.textInput(key);
      harness.pane.terminal.write(key);
    }
    await tester.pump();

    final after = cardIdentities(tester);
    // ignore: avoid_print
    print(
      'EXPLORER-TRIGGER keystrokes cards=${before.length} '
      'rebuilt=${changed(before, after)}',
    );
    expect(changed(before, after), 0);
  });

  testWidgets(
    'a status-registry cycle that finds nothing new rebuilds no card',
    (tester) async {
      final harness = await pump(tester);
      final registry = harness.container.read(sessionStatusRegistryProvider);

      // The first cycle is a first observation and may legitimately publish.
      await registry.cycle();
      await tester.pumpAndSettle();
      final before = cardIdentities(tester);

      // Ten more ticks with nothing changing underneath — the steady state the
      // user is in while they type.
      for (var i = 0; i < 10; i++) {
        clock.now = clock.now.add(kStatusCycleInterval);
        await registry.cycle();
        await tester.pump();
      }

      final after = cardIdentities(tester);
      // ignore: avoid_print
      print(
        'EXPLORER-TRIGGER registry-cycles cards=${before.length} '
        'rebuilt=${changed(before, after)} cycles=${registry.cycles}',
      );
      expect(changed(before, after), 0);
    },
  );

  testWidgets('a workspace mutation does rebuild every visible card', (
    tester,
  ) async {
    // The control: without it, "nothing rebuilt" could just mean the counter
    // cannot see a rebuild. The sessions revision is what the panel watches
    // directly, and bumping it must move every card on screen.
    final harness = await pump(tester);
    final before = cardIdentities(tester);

    harness.container.read(sessionsRevisionProvider.notifier).bump();
    await tester.pump();

    final after = cardIdentities(tester);
    // ignore: avoid_print
    print(
      'EXPLORER-TRIGGER sessions-revision cards=${before.length} '
      'rebuilt=${changed(before, after)}',
    );
    expect(changed(before, after), before.length);
  });

  testWidgets('opening a second terminal tab rebuilds no session card', (
    tester,
  ) async {
    // The terminal layout republishes its whole state on every structural
    // change, and `sessionWhereaboutsProvider` watches it — but the value it
    // produces is unchanged, so Riverpod stops there and no card is touched.
    final harness = await pump(tester);
    final before = cardIdentities(tester);

    harness.container
        .read(terminalSessionsControllerProvider.notifier)
        .openTab(TerminalProfile.powerShell, workingDirectory: r'C:\hub');
    await tester.pumpAndSettle();

    final after = cardIdentities(tester);
    // ignore: avoid_print
    print(
      'EXPLORER-TRIGGER terminal-layout-change cards=${before.length} '
      'rebuilt=${changed(before, after)}',
    );
    expect(changed(before, after), 0);
  });
}

CommandResult _git(CommandRequest request) =>
    const CommandResult(exitCode: 0, stdout: '', stderr: '');
