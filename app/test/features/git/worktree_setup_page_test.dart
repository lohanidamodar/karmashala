import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/git/application/worktree_setup_providers.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala/src/features/git/presentation/worktree_setup_dialog.dart';
import 'package:karmashala/src/features/git/presentation/worktree_setup_page.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/settings/presentation/settings_nav.dart';
import 'package:karmashala/src/features/settings/presentation/settings_screen.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// Settings → Projects → Worktree setup: where the setting is written, and where its verdict
/// is read.
///
/// The two are on one page on purpose. A setup runs unattended for a worktree
/// the user asked for while thinking about something else, so the place they
/// configure it has to be the place that says whether it worked.
void main() {
  late AppDatabase db;
  late ProviderContainer container;

  const worktree = EnvironmentPath(
    environmentId: 'wsl:Ubuntu',
    path: '/home/me/.karmashala-worktrees/app-s1',
  );

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db)
      ..upsert(windowsEnv())
      ..upsert(wslEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(
      db,
    ).insert(repository(environmentId: 'wsl:Ubuntu', path: '/home/me/app'));
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(
          FixedClock(testTime.add(const Duration(hours: 2))),
        ),
      ],
    );
  });
  tearDown(() {
    container.dispose();
    db.close();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: WorktreeSetupPage()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  void configure([WorktreeSetup? setup]) => container
      .read(worktreeSetupControllerProvider)
      .save(
        'r1',
        setup ??
            const WorktreeSetup(
              command: ['flutter', 'pub', 'get'],
              copyPaths: ['.dart_tool', 'macos/Vendor'],
            ),
      );

  testWidgets('nothing configured says so, and offers the way in', (
    tester,
  ) async {
    await pumpPage(tester);
    expect(find.text('WORKTREE SETUP'), findsOneWidget);
    expect(find.text('No checkout has a setup yet.'), findsOneWidget);
    expect(find.text('Add a checkout'), findsOneWidget);
  });

  testWidgets('the checkouts on offer are house menu rows, name over path', (
    tester,
  ) async {
    await pumpPage(tester);
    await tester.tap(find.text('Add a checkout'));
    await tester.pumpAndSettle();

    expect(find.byType(DesktopMenuDetailItem<String>), findsOneWidget);
    expect(find.text('app'), findsOneWidget);
    expect(find.text('/home/me/app'), findsOneWidget);
  });

  testWidgets('a configured checkout shows what will happen and where', (
    tester,
  ) async {
    configure();
    await pumpPage(tester);

    expect(find.text('app'), findsOneWidget);
    expect(find.text('flutter pub get'), findsOneWidget);
    expect(find.text('.dart_tool, macos/Vendor'), findsOneWidget);
    // The environment is on the card because it decides where both halves run.
    expect(find.text('WSL · Ubuntu'), findsOneWidget);
    // Configured, so it is no longer offered as an addition.
    expect(find.text('Add a checkout'), findsNothing);
  });

  testWidgets('a failed setup is on the card, in words, with its age', (
    tester,
  ) async {
    configure();
    container
        .read(worktreeSetupDaoProvider)
        .record(
          WorktreeSetupReport(
            repositoryId: 'r1',
            worktreePath: worktree.path,
            environmentId: 'wsl:Ubuntu',
            ranAt: testTime,
            copies: const [
              WorktreeCopyVerdict(
                path: 'macos/Vendor',
                result: WorktreeCopyResult.failed,
                reason: 'Copy failed: Permission denied.',
              ),
            ],
            command: const WorktreeCommandVerdict(
              result: WorktreeCommandResult.failed,
              reason:
                  'Exited with code 1. Its output is in the pane it ran in.',
              command: ['flutter', 'pub', 'get'],
              paneId: 'pane-1',
              exitCode: 1,
            ),
          ),
        );
    container.read(worktreeSetupRevisionProvider.notifier).bump();
    await pumpPage(tester);

    expect(find.textContaining('app-s1'), findsOneWidget);
    expect(find.textContaining('needs attention'), findsOneWidget);
    // §19: the reading carries its age.
    expect(find.textContaining('2h ago'), findsOneWidget);
    expect(
      find.text('macos/Vendor: Copy failed: Permission denied.'),
      findsOneWidget,
    );
    expect(
      find.text('Exited with code 1. Its output is in the pane it ran in.'),
      findsOneWidget,
    );
  });

  testWidgets('a clean setup is one quiet line, not a wall', (tester) async {
    configure();
    container
        .read(worktreeSetupDaoProvider)
        .record(
          WorktreeSetupReport(
            repositoryId: 'r1',
            worktreePath: worktree.path,
            environmentId: 'wsl:Ubuntu',
            ranAt: testTime,
            copies: const [
              WorktreeCopyVerdict(
                path: '.dart_tool',
                result: WorktreeCopyResult.copied,
                reason: 'Copied with `cp -a`.',
              ),
            ],
          ),
        );
    container.read(worktreeSetupRevisionProvider.notifier).bump();
    await pumpPage(tester);

    expect(find.textContaining('set up'), findsOneWidget);
    expect(find.textContaining('needs attention'), findsNothing);
    expect(find.text('Copied with `cp -a`.'), findsNothing);
  });

  testWidgets('a setup that ran while the page is open appears on it', (
    tester,
  ) async {
    configure();
    await pumpPage(tester);
    expect(find.textContaining('needs attention'), findsNothing);

    // What a session launch does: record, then bump. Nothing polls, and the
    // page is not reopened.
    container
        .read(worktreeSetupDaoProvider)
        .record(
          WorktreeSetupReport(
            repositoryId: 'r1',
            worktreePath: worktree.path,
            environmentId: 'wsl:Ubuntu',
            ranAt: testTime,
            copies: const [
              WorktreeCopyVerdict(
                path: 'lib',
                result: WorktreeCopyResult.refusedTracked,
                reason: 'refused',
              ),
            ],
          ),
        );
    container.read(worktreeSetupRevisionProvider.notifier).bump();
    await tester.pumpAndSettle();

    expect(find.textContaining('needs attention'), findsOneWidget);
  });

  testWidgets('Remove takes the setting away', (tester) async {
    configure();
    await pumpPage(tester);
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(find.text('No checkout has a setup yet.'), findsOneWidget);
    expect(container.read(worktreeSetupDaoProvider).getAll(), isEmpty);
  });

  testWidgets('the page is reachable by looking for it in Settings', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: SettingsScreen(initialSection: SettingsSectionId.projects),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('WORKTREE SETUP'), findsOneWidget);
  });

  group('the editor', () {
    Future<WorktreeSetup?> open(
      WidgetTester tester, {
      WorktreeSetup existing = const WorktreeSetup(),
    }) async {
      WorktreeSetup? saved;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    saved = await WorktreeSetupDialog.show(
                      context,
                      checkoutName: 'app',
                      existing: existing,
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return saved;
    }

    testWidgets('shows the argv it will store, not the line typed', (
      tester,
    ) async {
      await open(tester);
      expect(find.text('Nothing will be run.'), findsOneWidget);
      await tester.enterText(
        find.byType(TextField).first,
        'pwsh -Command "Write-Host two words"',
      );
      await tester.pump();
      // The split is visible before it is saved: three arguments, and the
      // quoted one has stayed one argument.
      expect(
        find.text('Will run: [pwsh] [-Command] [Write-Host two words]'),
        findsOneWidget,
      );
    });

    testWidgets('refuses a copy path in words, and will not save it', (
      tester,
    ) async {
      await open(tester);
      await tester.enterText(find.byType(TextField).last, '../../etc/passwd');
      await tester.pumpAndSettle();
      expect(find.textContaining('climbs out of the checkout'), findsOneWidget);
      final save = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(save.onPressed, isNull, reason: 'the refusal is not advisory');
    });

    testWidgets('saves argv and the path list', (tester) async {
      await open(tester);
      await tester.enterText(find.byType(TextField).first, 'flutter pub get');
      await tester.enterText(
        find.byType(TextField).last,
        '.dart_tool\n\nmacos/Vendor\n',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      // The dialog's own result is what the page writes; asserted through the
      // page in the Remove test above.
      expect(find.byType(WorktreeSetupDialog), findsNothing);
    });

    testWidgets('an existing setting comes back as one editable line', (
      tester,
    ) async {
      await open(
        tester,
        existing: const WorktreeSetup(
          command: ['pwsh', '-Command', 'Write-Host two words'],
          copyPaths: ['.dart_tool'],
        ),
      );
      expect(
        find.text('pwsh -Command "Write-Host two words"'),
        findsOneWidget,
        reason: 'a round-trip through the editor must not split an argument',
      );
    });

    testWidgets('saves the teardown command as argv', (tester) async {
      WorktreeSetup? saved;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async => saved = await WorktreeSetupDialog.show(
                    context,
                    checkoutName: 'app',
                    existing: const WorktreeSetup(),
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

      await tester.enterText(
        find.byKey(const ValueKey('worktree-setup-teardown')),
        'docker compose -f "dev stack.yml" down',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(saved?.teardown, [
        'docker',
        'compose',
        '-f',
        'dev stack.yml',
        'down',
      ]);
    });

    testWidgets('there is no way to ask for a link', (tester) async {
      await open(tester);
      for (final word in ['Symlink', 'symlink', 'Link', 'Share', 'Junction']) {
        expect(
          find.textContaining(word),
          findsNothing,
          reason: 'copied, never shared — and the setting cannot say otherwise',
        );
      }
    });
  });
}
