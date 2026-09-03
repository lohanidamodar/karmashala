import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';
import 'package:karmashala/src/features/environments/application/environment_health.dart';
import 'package:karmashala/src/features/environments/presentation/environment_health_dialog.dart';
import 'package:karmashala/src/features/fanout/presentation/comparison_view.dart';
import 'package:karmashala/src/features/fanout/presentation/fanout_dialog.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/git/domain/file_change.dart';
import 'package:karmashala/src/features/git/presentation/changes_view.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala/src/features/projects/presentation/new_project_dialog.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_handoff_service.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/sessions/domain/session.dart';
import 'package:karmashala/src/features/sessions/domain/session_delivery.dart';
import 'package:karmashala/src/features/sessions/domain/session_fork.dart';
import 'package:karmashala/src/features/sessions/domain/session_status.dart';
import 'package:karmashala/src/features/sessions/presentation/delivery_strip.dart';
import 'package:karmashala/src/features/sessions/presentation/new_session_dialog.dart';
import 'package:karmashala/src/features/notifications/application/session_status_registry.dart';
import 'package:karmashala/src/features/settings/presentation/settings_nav.dart';
import 'package:karmashala/src/features/settings/presentation/watch_set_section.dart';
import 'package:karmashala/src/features/settings/presentation/settings_screen.dart';
import 'package:karmashala/src/features/ssh/domain/ssh_host.dart';
import 'package:karmashala/src/features/ssh/presentation/remote_file_browser_dialog.dart';
import 'package:karmashala/src/features/ssh/presentation/ssh_host_dialog.dart';
import 'package:karmashala/src/features/detail/presentation/repository_info_view.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_theme_controller.dart';
import 'package:karmashala/src/features/terminal/data/system_terminal_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../features/fanout/comparison_fixtures.dart';
import '../features/terminal/fake_instance.dart';
import '../support/fake_command_runner.dart';
import '../support/fakes.dart';
import '../support/fixtures.dart';
import '../support/window_matrix.dart';

/// The minimum-window and accessibility matrix, applied to the surfaces the
/// audit flagged.
///
/// Karmashala supports a 720x560 window. `FanOutDialog` asks for 1180x780 and
/// several dialogs ask for 420-620, and nothing in the suite pumped any of them
/// small enough to notice. These do — at 720x560, at 1440x900 as a control, and
/// at 720x560 with text scaled to 1.3 — and they check keyboard reachability and
/// accessible names at the same time, because those break in the same place and
/// for the same reason.
///
/// See `test/support/window_matrix.dart` for what each cell asserts, and
/// `window_matrix_test.dart` for the proof that it can actually fail.

/// Nothing here may shell out: the git-backed panels would otherwise probe a
/// real repository that is not there.
///
/// The return type is inferred for the same reason `fakeTerminalOverrides` does
/// it — Riverpod's `Override` is sealed and its public library does not export
/// it, so it cannot be written down.
// ignore: strict_top_level_inference
noProcessOverrides() => [
  commandRunnerFactoryProvider.overrideWithValue(
    FakeCommandRunnerFactory(fallback: FakeCommandRunner()),
  ),
  hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
];

Widget app(ProviderContainer container, Widget home) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: home, debugShowCheckedModeBanner: false),
    );

Widget panel(ProviderContainer container, Widget body) =>
    app(container, Scaffold(body: body));

void main() {
  group('FanOutDialog', () {
    // The dialog the audit named: it asks for 1180x780, which is 460 wider and
    // 220 taller than the whole supported window.
    AppDatabase seeded() {
      final db = seedDatabase();
      AgentInstallationDao(db)
        ..insert(agentInstallation(id: 'a1', agentId: 'claudeCode'))
        ..insert(agentInstallation(id: 'a2', agentId: 'codex'));
      addTearDown(db.close);
      return db;
    }

    ProviderContainer withRepositorySelected(AppDatabase db) {
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          ...noProcessOverrides(),
        ],
      );
      addTearDown(container.dispose);
      container.read(selectedRepositoryIdProvider.notifier).select('r1');
      return container;
    }

    testWidgets('the comparison list', (tester) async {
      final container = withRepositorySelected(seeded());
      await expectSurvivesWindowMatrix(
        tester,
        build: () => app(container, const FanOutDialog()),
        because: 'the dialog requests 1180x780 inside a 720x560 window',
      );
    });

    testWidgets('the new-fan-out setup form', (tester) async {
      final container = withRepositorySelected(seeded());
      await expectSurvivesWindowMatrix(
        tester,
        build: () => app(container, const FanOutDialog()),
        warmUp: (tester) async {
          await tester.tap(find.text('New fan-out'));
        },
        because:
            'the setup form stacks a prompt field, an agent list and a '
            'button row inside that same box',
      );
    });

    testWidgets('an open comparison', (tester) async {
      final container = withRepositorySelected(seeded());
      await expectSurvivesWindowMatrix(
        tester,
        build: () =>
            app(container, const FanOutDialog(initialComparisonId: 'cmp-1')),
        because: 'candidate columns are a fixed 372 wide each',
      );
    });
  });

  testWidgets('ComparisonView on its own', (tester) async {
    final db = seedDatabase();
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        ...noProcessOverrides(),
      ],
    );
    addTearDown(container.dispose);

    await expectSurvivesWindowMatrix(
      tester,
      build: () => panel(
        container,
        ComparisonView(comparisonId: 'cmp-1', onBack: () {}),
      ),
      because: 'three candidate columns of 372 do not fit 720',
    );
  });

  group('NewSessionDialog', () {
    ProviderContainer prepared() {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      ExecutionEnvironmentDao(db).upsert(windowsEnv());
      ProjectDao(db).insert(project());
      RepositoryDao(db).insert(repository());
      AgentInstallationDao(db).insert(agentInstallation());

      final container = ProviderContainer(
        overrides: [
          ...fakeTerminalOverrides(database: db),
          ...noProcessOverrides(),
          // Detecting terminals really probes PATH; the picker only needs a list.
          availableSystemTerminalsProvider.overrideWith(
            (ref) async => const [
              SystemTerminal(
                kind: SystemTerminalKind.windowsTerminal,
                label: 'Windows Terminal',
                executable: 'wt.exe',
              ),
              SystemTerminal(
                kind: SystemTerminalKind.powerShell,
                label: 'PowerShell',
                executable: 'powershell.exe',
              ),
            ],
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(selectedRepositoryIdProvider.notifier).select('r1');
      return container;
    }

    testWidgets('running in the app', (tester) async {
      final container = prepared();
      await expectSurvivesWindowMatrix(
        tester,
        build: () => app(container, const NewSessionDialog()),
      );
    });

    testWidgets('running in an external terminal', (tester) async {
      // Picking the external terminal adds a whole dropdown to a dialog that
      // was already close to the bottom of the window.
      final container = prepared();
      await expectSurvivesWindowMatrix(
        tester,
        build: () => app(container, const NewSessionDialog()),
        warmUp: (tester) async {
          // Scrolled to, then scrolled back. The destination picker put a
          // project and a checkout above this toggle, so at 720x560 with text
          // at 1.3x it is below the fold of a dialog that is deliberately
          // `scrollable: true`. Reaching it is a scroll for the user too — but
          // the state worth measuring is the dialog as it is *met*, so the
          // warm-up returns it to the top: a forward Tab scrolls a stop below
          // the fold into view, and one left above it does not come back.
          await tester.ensureVisible(find.text('External terminal'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('External terminal'));
          await tester.pumpAndSettle();
          // All the way back: the dialog's own Close button is the first thing
          // in its scroll view, so this leaves the surface at offset zero.
          await tester.ensureVisible(find.byTooltip('Close'));
        },
      );
    });
  });

  testWidgets('DeliveryStrip', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
    SessionDao(db).insert(
      Session(
        id: 's1',
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'Fix the login',
        useWorktree: true,
        worktree: const EnvironmentPath(
          environmentId: 'windows',
          path: r'C:\src\.karmashala-worktrees\app-s1',
        ),
        status: SessionStatus.idle,
        createdAt: testTime,
      ),
    );

    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        ...noProcessOverrides(),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        sessionDeliveryProvider.overrideWith(
          (ref, _) async => const SessionDelivery(
            branch: 'session/fix-the-login',
            baseBranch: 'origin/main',
            hasRemote: true,
            dirtyFiles: 2,
            aheadOfBase: 3,
            hasWorktree: true,
          ),
        ),
        sessionContinuationProvider.overrideWith(
          (ref, _) => SessionContinuation(
            targets: const [],
            plan: SessionForkPlan.decide(
              descriptor: null,
              agentName: 'Test CLI',
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await expectSurvivesWindowMatrix(
      tester,
      build: () => panel(container, const DeliveryStrip(sessionId: 's1')),
      because: 'the strip is a single row of chips and stage text',
    );
  });

  testWidgets('SshHostDialog', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    ExecutionEnvironmentDao(db)
      ..upsert(windowsEnv())
      ..upsert(wslEnv(id: 'wsl:Ubuntu', distro: 'Ubuntu'));

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        ...noProcessOverrides(),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator()),
      ],
    );
    addTearDown(container.dispose);

    await expectSurvivesWindowMatrix(
      tester,
      build: () => app(container, const SshHostDialog()),
      because: 'the form is a fixed 560 wide with six fields stacked in it',
    );
  });

  testWidgets('RepositoryInfoView', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());

    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        ...noProcessOverrides(),
      ],
    );
    addTearDown(container.dispose);
    container.read(selectedProjectIdProvider.notifier).select('p1');
    container.read(selectedRepositoryIdProvider.notifier).select('r1');

    await expectSurvivesWindowMatrix(
      tester,
      build: () => panel(container, const RepositoryInfoView()),
      because: 'the panel is the narrowest surface in the app',
    );
  });

  // --- B3: the four hard-sized dialogs the senior review found uncovered -----
  //
  // Each of these asks for a fixed box that is wider or taller than the whole
  // supported window, and none of them had a test that pumped it small enough
  // to notice.

  testWidgets('the full-screen diff dialog', (tester) async {
    // `_DiffFullscreenDialog` is private, so it is reached the way a user
    // reaches it: through the "Open full screen" button on a changed file. It
    // constrains itself to 1200x900 around a `width: 1400` child.
    Widget build() => ProviderScope(
      overrides: [
        repositoryChangesProvider.overrideWith(
          (ref) async => const [
            FileChange(
              path: 'lib/src/features/git/presentation/changes_view.dart',
              type: FileChangeType.modified,
              staged: false,
              unstaged: true,
            ),
          ],
        ),
        recentCommitsProvider.overrideWith((ref) async => const []),
        fileDiffByPathProvider(
          'lib/src/features/git/presentation/changes_view.dart',
        ).overrideWith(
          (ref) async =>
              '@@ -1,2 +1,2 @@\n'
              '-final short = 1;\n'
              // A line far longer than the window, which is what the 1400-wide
              // horizontal scroller inside the dialog exists for.
              '+final long = ${'x' * 400};\n',
        ),
        ...noProcessOverrides(),
      ],
      child: const MaterialApp(
        home: Scaffold(body: ChangesView(repositoryName: 'app')),
      ),
    );

    await expectSurvivesWindowMatrix(
      tester,
      build: build,
      warmUp: (tester) async {
        await tester.tap(find.byTooltip('Open full screen'));
        await tester.pump();
        // "Copy diff" exists only inside the dialog, so this is what stops the
        // cell from passing vacuously if the tap stopped opening it.
        expect(find.byTooltip('Copy diff'), findsOneWidget);
      },
      because:
          'the dialog constrains itself to 1200x900 around a 1400-wide diff',
    );
  });

  testWidgets('RemoteFileBrowserDialog', (tester) async {
    // Offline on purpose: the host is not saved, so `forHostId` refuses before
    // any socket is opened and the dialog settles into its error state. The
    // 620x460 content box under test is the same in every state, and the live
    // listing is covered by `test/features/ssh/live_ssh_ui_test.dart`.
    final db = AppDatabase.memory();
    addTearDown(db.close);
    ExecutionEnvironmentDao(db).upsert(windowsEnv());

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        ...noProcessOverrides(),
        clockProvider.overrideWithValue(FixedClock(testTime)),
      ],
    );
    addTearDown(container.dispose);

    final host = SshHost(
      id: 'unsaved',
      name: 'build-box',
      host: 'build-box.example',
      port: 22,
      username: 'dev',
      authMethod: SshAuthMethod.privateKey,
      createdAt: testTime,
    );

    await expectSurvivesWindowMatrix(
      tester,
      build: () => app(container, RemoteFileBrowserDialog(host: host)),
      because: 'the content is a hard 620x460 inside a 720x560 window',
    );
  });

  testWidgets('EnvironmentHealthDialog', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    ExecutionEnvironmentDao(db)
      ..upsert(windowsEnv())
      ..upsert(wslEnv(id: 'wsl:Ubuntu', distro: 'Ubuntu'));

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        ...noProcessOverrides(),
        // Checking health really runs `git --version` per environment; the
        // dialog only needs rows to lay out.
        environmentHealthProvider.overrideWith(
          (ref) async => [
            EnvironmentHealth(
              environment: windowsEnv(),
              level: HealthLevel.healthy,
              summary: 'Ready',
              installations: const [],
              gitVersion: 'git version 2.45.1.windows.1',
            ),
            EnvironmentHealth(
              environment: wslEnv(id: 'wsl:Ubuntu', distro: 'Ubuntu'),
              level: HealthLevel.failed,
              summary:
                  'git is not installed in this distribution, so worktrees '
                  'cannot be created here',
              installations: const [],
            ),
          ],
        ),
      ],
    );
    addTearDown(container.dispose);

    await expectSurvivesWindowMatrix(
      tester,
      build: () => app(container, const EnvironmentHealthDialog()),
      because: 'the content is a hard 620x420 inside a 720x560 window',
    );
  });

  group('SettingsScreen', () {
    // The Loop 79 master-detail redesign, in every standard cell plus the
    // desktop 125% cell — the scale the in-app text-size setting offers, at
    // the size it will actually be used.
    /// [coverage] stands in for the status registry's watch-set measurement,
    /// which no cycle has produced in a widget test.
    ProviderContainer prepared({SessionStatusCoverage? coverage}) {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          ...noProcessOverrides(),
          // Theme discovery reads real Ghostty/Warp directories.
          discoveredTerminalThemesProvider.overrideWithValue(const []),
          if (coverage != null)
            sessionStatusCoverageProvider.overrideWith(
              (ref) => Stream.value(coverage),
            ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    testWidgets('the default landing (nav plus Appearance)', (tester) async {
      await expectSurvivesWindowMatrix(
        tester,
        build: () => app(prepared(), const SettingsScreen()),
        matrix: const [...windowMatrix, desktopLargeText],
        because:
            'the nav rail, the filter and the appearance rows must hold at '
            'the minimum window and at 125% text',
      );
    });

    testWidgets('the permissions section, with Codex\'s two axes', (
      tester,
    ) async {
      // The section that grew: a per-agent card now draws one dropdown per
      // axis per purpose, so Codex's card is **four** controls rather than
      // two, and their labels are the CLI's own words rather than three short
      // shared ones. Four dropdowns across do not fit 720x560, which is why
      // the card wraps — and this is what proves it does.
      await expectSurvivesWindowMatrix(
        tester,
        build: () => app(
          prepared(),
          const SettingsScreen(initialSection: SettingsSectionId.permissions),
        ),
        matrix: const [...windowMatrix, desktopLargeText],
        because:
            'a two-axis agent draws four permission dropdowns, and they must '
            'wrap rather than overflow at the minimum window and at 125% text',
      );
    });

    testWidgets('the diagnostics section, watch-set readout and all', (
      tester,
    ) async {
      await expectSurvivesWindowMatrix(
        tester,
        build: () => app(
          prepared(),
          const SettingsScreen(initialSection: SettingsSectionId.diagnostics),
        ),
        matrix: const [...windowMatrix, desktopLargeText],
        because:
            'the watch-set rows put a long sentence of help beside a number, '
            'which is the shape that wraps badly at the minimum window',
      );
    });

    testWidgets('the diagnostics section with a coverage readout to show', (
      tester,
    ) async {
      // The measured state, not the "nothing yet" one: three value rows and,
      // when the rotation is behind, a paragraph of error text under them.
      await expectSurvivesWindowMatrix(
        tester,
        build: () => app(
          prepared(
            coverage: const SessionStatusCoverage(
              tracked: 900,
              hookAnswered: 10,
              probeCandidates: 890,
              probed: 24,
              neverProbed: 400,
              probeFailures: 3,
              rotationPeriod: Duration(seconds: 150),
            ),
          ),
          const SettingsScreen(initialSection: SettingsSectionId.diagnostics),
        ),
        matrix: const [...windowMatrix, desktopLargeText],
        because:
            'the behind-rotation warning is the longest text the page can '
            'show',
      );
    });

    testWidgets('the terminal section', (tester) async {
      await expectSurvivesWindowMatrix(
        tester,
        build: () => app(
          prepared(),
          const SettingsScreen(initialSection: SettingsSectionId.terminal),
        ),
        matrix: const [...windowMatrix, desktopLargeText],
        because:
            'chord rows, dropdowns and the font stepper stack tightest of '
            'all the sections',
      );
    });
  });

  testWidgets('NewProjectDialog', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    ExecutionEnvironmentDao(db)
      ..upsert(windowsEnv())
      ..upsert(wslEnv(id: 'wsl:Ubuntu', distro: 'Ubuntu'));

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        ...noProcessOverrides(),
        clockProvider.overrideWithValue(FixedClock(testTime)),
      ],
    );
    addTearDown(container.dispose);

    await expectSurvivesWindowMatrix(
      tester,
      build: () => app(container, const NewProjectDialog()),
      because:
          'a 460-wide column of two fields, a dropdown and a button row, '
          'which grows a preview line and an error banner as it is used',
    );
  });
}
