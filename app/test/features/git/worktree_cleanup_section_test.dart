import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/git/application/worktree_cleanup_policy.dart';
import 'package:karmashala/src/features/git/application/worktree_cleanup_providers.dart';
import 'package:karmashala/src/features/git/application/worktree_cleanup_service.dart';
import 'package:karmashala/src/features/git/data/worktree_cleanup_store.dart';
import 'package:karmashala/src/features/git/presentation/worktree_setup_page.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_store/database.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// A service whose preview is scripted: the page is under test, not git.
class _CannedService extends WorktreeCleanupService {
  _CannedService(this.report, Clock clock)
    : super(
        projects: () => const [],
        repositoriesOf: (_) => const [],
        presenceOf: (_) async => GitPresence.unknown,
        familyKeyOf: (_) async => null,
        environmentKind: (_) => null,
        gitFor: (_) => throw StateError('no git'),
        removeIfClean: (_, _) => throw StateError('no removal'),
        sessions: () => const [],
        isLive: (_) => false,
        liveTerminalDirectories: () => const [],
        lastEventAt: (_) => null,
        createdAt: (_) => null,
        clock: clock,
      );

  final WorktreeCleanupReport report;
  int previews = 0;

  @override
  Future<WorktreeCleanupReport> preview(
    WorktreeCleanupSettings settings,
  ) async {
    previews++;
    return report;
  }
}

void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late _CannedService service;

  const repo = EnvironmentPath(environmentId: 'windows', path: r'C:\src\app');
  WorktreeFacts facts(String branch) => WorktreeFacts(
    projectId: 'p1',
    projectName: 'Demo',
    repo: repo,
    path: EnvironmentPath(
      environmentId: 'windows',
      path: 'C:\\src\\.karmashala-worktrees\\app-$branch',
    ),
    branch: branch,
  );

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    final clock = FixedClock(testTime);
    service = _CannedService(
      WorktreeCleanupReport(
        at: testTime,
        dryRun: true,
        verdicts: [
          WorktreeCleanupVerdict(
            facts: facts('landed'),
            outcome: WorktreeCleanupOutcome.wouldRemove,
            matched: const [WorktreeCleanupRule.merged],
          ),
          WorktreeCleanupVerdict(
            facts: facts('wip'),
            outcome: WorktreeCleanupOutcome.kept,
            matched: const [WorktreeCleanupRule.merged],
            refusals: const [
              WorktreeRefusal(
                WorktreeRefusalKind.uncommittedChanges,
                '1 uncommitted or untracked path: notes.txt.',
              ),
            ],
          ),
        ],
      ),
      clock,
    );
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(clock),
        worktreeCleanupServiceProvider.overrideWithValue(service),
      ],
    );
  });
  tearDown(() {
    container.dispose();
    db.close();
  });

  Future<void> pumpPage(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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

  Finder cleanupNow() => find.byKey(const ValueKey('worktree-cleanup-now'));

  WorktreeCleanupSettings stored() => WorktreeCleanupStore(db).settings();

  testWidgets('off by default, with the squash-merge caveat on the page', (
    tester,
  ) async {
    await pumpPage(tester, const Size(1440, 900));

    final toggle = tester.widget<Switch>(
      find.descendant(
        of: find.byKey(const ValueKey('worktree-cleanup-enabled')),
        matching: find.byType(Switch),
      ),
    );
    expect(toggle.value, isFalse);
    expect(tester.widget<TextButton>(cleanupNow()).onPressed, isNull);
    final caveat = tester.widget<Text>(
      find.byKey(const ValueKey('worktree-cleanup-squash-caveat')),
    );
    expect(caveat.data, contains('squash merge'));
    expect(stored().enabled, isFalse);
  });

  testWidgets('turning the default on is stored and enables "Clean up now"', (
    tester,
  ) async {
    await pumpPage(tester, const Size(1440, 900));

    await tester.tap(find.byKey(const ValueKey('worktree-cleanup-enabled')));
    await tester.pumpAndSettle();

    expect(stored().enabled, isTrue);
    expect(stored().changedAt, testTime);
    expect(tester.widget<TextButton>(cleanupNow()).onPressed, isNotNull);
  });

  testWidgets('a project can opt out of the default', (tester) async {
    await pumpPage(tester, const Size(1440, 900));

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('worktree-cleanup-project p1')),
        matching: find.byType(DropdownButton<WorktreeCleanupMode>),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Off').last);
    await tester.pumpAndSettle();

    expect(stored().policyFor('p1').mode, WorktreeCleanupMode.off);
  });

  for (final size in const [Size(390, 844), Size(1440, 900)]) {
    testWidgets('the preview names what would go and why the rest stay '
        '(${size.width.toInt()} wide)', (tester) async {
      await pumpPage(tester, size);

      await tester.ensureVisible(
        find.byKey(const ValueKey('worktree-cleanup-preview')),
      );
      await tester.tap(find.byKey(const ValueKey('worktree-cleanup-preview')));
      await tester.pumpAndSettle();

      expect(service.previews, 1);
      expect(find.textContaining('cleanup is off'), findsOneWidget);
      expect(find.text('Would remove (1)'), findsOneWidget);
      expect(find.text('Kept (1)'), findsOneWidget);
      expect(find.textContaining('landed · Demo'), findsOneWidget);
      expect(
        find.textContaining('uncommitted changes — 1 uncommitted'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
