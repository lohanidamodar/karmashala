import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/explorer/application/unresumable_sessions.dart';
import 'package:karmashala/src/features/explorer/presentation/unresumable_sessions_dialog.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_cli_store_locator.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/permission_fixtures.dart';
import '../../support/window_matrix.dart';
import '../terminal/fake_instance.dart';
import '../../support/temp_directory.dart';
import 'package:agent_cli/read.dart';

/// **What the user sees before anything is removed.**
///
/// The owner asked for "a quick button that will remove all those". A button
/// on its own could not be honest about this state, so what they get is a
/// reading: the count, the rows behind the count, the ones nothing could judge,
/// and how old the reading is. These tests are that contract.
///
/// Checked at both sizes §11 names — 390x844 and 1440x900 — because the panel
/// is sized off the viewport rather than off the desktop, and a 560px content
/// box on a 390px phone is exactly the overflow nobody notices until they
/// resize.

const _claudeish = AgentDescriptor(
  id: 'claudeish',
  displayName: 'Claudeish',
  binaries: AgentBinaries(windows: ['claudeish'], posix: ['claudeish']),
  launch: AgentLaunchSpec(
    permission: testPermissionSupport,
    sessionIdAssignment: AgentSessionIdAssignment.flag('--session-id'),
  ),
  store: AgentStoreSpec(homeDirectoryName: '.claude'),
);

class _StaticSettings extends SettingsController {
  @override
  Settings build() => const Settings();
}

/// The phone cell §11 asks for. Kept local rather than added to the shared
/// matrix, so this file cannot change what every other surface asserts.
const _phoneWindow = WindowCell('390x844 (phone)', Size(390, 844));

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('karmashala_udlg_'));
  tearDown(() => removeTempDirectory(tmp));

  String storeHome() => p.join(tmp.path, '.claude');

  void emptyStore() =>
      Directory(p.join(storeHome(), 'projects')).createSync(recursive: true);

  AppDatabase seededDatabase() {
    final db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ExecutionEnvironmentDao(db).upsert(wslEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation(agentId: 'claudeish'));
    return db;
  }

  void seedDeadRow(
    AppDatabase db, {
    required String id,
    required String title,
    EnvironmentPath? workingDirectory,
  }) {
    SessionDao(db).insert(
      session(id: id, title: title).copyWith(
        externalSessionId: id,
        status: SessionStatus.running,
        createdAt: testTime.subtract(const Duration(hours: 2)),
        workingDirectory: workingDirectory,
      ),
    );
  }

  ProviderContainer containerOver(AppDatabase db, {bool locatable = true}) {
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(),
        ),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('s-')),
        agentRegistryProvider.overrideWithValue(
          const AgentRegistry([ClaudeCodeAdapter(descriptor: _claudeish)]),
        ),
        settingsControllerProvider.overrideWith(_StaticSettings.new),
        agentSessionStatusProvider.overrideWith(
          (ref, id) => const Stream<AgentStatusReport>.empty(),
        ),
        cliStoreLocatorProvider.overrideWithValue(
          FixedLocator([
            if (locatable)
              CliStore(
                environmentId: 'windows',
                homesByAgentId: {'claudeish': storeHome()},
              ),
          ]),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Widget host(ProviderContainer container) => UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(home: Scaffold(body: UnresumableSessionsDialog())),
  );

  /// The reading is taken **before** the widget is pumped, and inside
  /// [WidgetTester.runAsync].
  ///
  /// Two separate reasons, and both had to be found the hard way:
  ///
  /// * `testWidgets` runs its body in a fake-async zone, where a `dart:io`
  ///   future never completes at all. The store pass is ordinary file I/O, so
  ///   it has to run through `runAsync` or the test hangs.
  /// * `pumpAndSettle` drives frames and timers, so it could not have awaited
  ///   that pass even in real time.
  ///
  /// Taking it up front also makes these tests about the rendering rather than
  /// about the scheduler: the panel's own `initState` sees a reading that has
  /// already run and does not take a second one.
  Future<void> pumpAt(
    WidgetTester tester,
    ProviderContainer container,
    Size size,
  ) async {
    await tester.runAsync(
      () => container.read(unresumableSessionsProvider.notifier).refresh(),
    );
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(host(container));
    await tester.pumpAndSettle();
  }

  for (final (label, size) in const [
    ('phone', Size(390, 844)),
    ('desktop', Size(1440, 900)),
  ]) {
    group('at $label', () {
      testWidgets('names the rows it will remove, and how many', (
        tester,
      ) async {
        final db = seededDatabase();
        addTearDown(db.close);
        emptyStore();
        seedDeadRow(db, id: 'dead-1', title: 'Refactor the parser');
        seedDeadRow(db, id: 'dead-2', title: 'Chase the flake');

        await pumpAt(tester, containerOver(db), size);

        // The rows themselves, not just a count — a set assembled from a scan
        // is exactly where a user needs to see what is in it.
        expect(find.text('Refactor the parser'), findsOneWidget);
        expect(find.text('Chase the flake'), findsOneWidget);
        expect(find.text('Remove 2 sessions'), findsOneWidget);
        expect(
          find.textContaining('2 sessions name conversations'),
          findsOneWidget,
        );
        // And whose store answered.
        expect(find.textContaining('Claudeish'), findsWidgets);
      });

      testWidgets('un-ticking a row takes it out of the count', (tester) async {
        final db = seededDatabase();
        addTearDown(db.close);
        emptyStore();
        seedDeadRow(db, id: 'dead-1', title: 'One');
        seedDeadRow(db, id: 'dead-2', title: 'Two');

        await pumpAt(tester, containerOver(db), size);
        expect(find.text('Remove 2 sessions'), findsOneWidget);

        await tester.tap(find.byType(Checkbox).first);
        await tester.pumpAndSettle();

        expect(find.text('Remove 1 session'), findsOneWidget);
      });

      testWidgets('removing takes the rows out of the workspace', (
        tester,
      ) async {
        final db = seededDatabase();
        addTearDown(db.close);
        emptyStore();
        seedDeadRow(db, id: 'dead-1', title: 'One');

        await pumpAt(tester, containerOver(db), size);
        await tester.tap(find.text('Remove 1 session'));
        await tester.pumpAndSettle();

        expect(SessionDao(db).getById('dead-1'), isNull);
        expect(find.text('One'), findsNothing);
        expect(
          find.textContaining('Every session here names a conversation'),
          findsOneWidget,
        );
      });

      testWidgets('a row nothing could judge is listed and has no checkbox', (
        tester,
      ) async {
        final db = seededDatabase();
        addTearDown(db.close);
        emptyStore();
        seedDeadRow(db, id: 'dead-1', title: 'Judged');
        // Runs in a distribution whose store was never located.
        seedDeadRow(
          db,
          id: 'unknown-1',
          title: 'Unjudged',
          workingDirectory: const EnvironmentPath(
            environmentId: 'wsl:Ubuntu',
            path: '/home/me/app',
          ),
        );

        await pumpAt(tester, containerOver(db), size);

        expect(find.text('Judged'), findsOneWidget);
        expect(find.text('Unjudged'), findsOneWidget);
        expect(
          find.textContaining('1 session could not be checked'),
          findsOneWidget,
        );
        expect(find.textContaining('could not check'), findsOneWidget);
        // One tickable row, so the uncertain one cannot be swept up by a
        // "remove everything listed" reflex — and neither verb is offered on
        // it, because a store we could not read may well still hold that
        // conversation.
        expect(find.byType(Checkbox), findsOneWidget);
        expect(find.byTooltip('Start a conversation here'), findsOneWidget);
        expect(find.text('Remove 1 session'), findsOneWidget);
      });

      testWidgets('a reading that read no store offers nothing at all', (
        tester,
      ) async {
        final db = seededDatabase();
        addTearDown(db.close);
        seedDeadRow(db, id: 'dead-1', title: 'Cannot say');

        await pumpAt(tester, containerOver(db, locatable: false), size);

        expect(
          find.textContaining('No CLI store could be read'),
          findsOneWidget,
        );
        expect(find.textContaining('Nothing will be removed'), findsOneWidget);
        expect(find.byType(Checkbox), findsNothing);
        // The verb is present and inert, so the count beside it is always the
        // count it would act on.
        final button = tester.widget<DestructiveButton>(
          find.byType(DestructiveButton),
        );
        expect(button.onPressed, isNull);
      });

      testWidgets('the reading carries its own age', (tester) async {
        final db = seededDatabase();
        addTearDown(db.close);
        emptyStore();
        seedDeadRow(db, id: 'dead-1', title: 'One');

        await pumpAt(tester, containerOver(db), size);

        // §19: a reading that is not live must not look live.
        expect(find.textContaining('Checked '), findsOneWidget);
        expect(find.text('Check again'), findsOneWidget);
      });

      testWidgets('an empty workspace says so rather than nothing', (
        tester,
      ) async {
        final db = seededDatabase();
        addTearDown(db.close);
        emptyStore();

        await pumpAt(tester, containerOver(db), size);

        expect(
          find.textContaining('Every session here names a conversation'),
          findsOneWidget,
        );
        expect(find.text('Remove 0 sessions'), findsOneWidget);
      });
    });
  }

  testWidgets('survives the window matrix and a phone', (tester) async {
    final db = seededDatabase();
    addTearDown(db.close);
    emptyStore();
    // Long titles, because a fixed content width and a one-line title are what
    // break first.
    seedDeadRow(
      db,
      id: 'dead-1',
      title: 'Rework the conversation store index so the sweep is one pass',
    );
    seedDeadRow(
      db,
      id: 'unknown-1',
      title: 'A session in a distribution that is not running right now',
      workingDirectory: const EnvironmentPath(
        environmentId: 'wsl:Ubuntu',
        path: '/home/me/app',
      ),
    );

    final container = containerOver(db);
    await tester.runAsync(
      () => container.read(unresumableSessionsProvider.notifier).refresh(),
    );

    await expectSurvivesWindowMatrix(
      tester,
      build: () => host(container),
      warmUp: (tester) => tester.pumpAndSettle(),
      matrix: const [...windowMatrix, _phoneWindow],
      because: 'the review is reachable from Quick open at any window size',
    );
  });
}
