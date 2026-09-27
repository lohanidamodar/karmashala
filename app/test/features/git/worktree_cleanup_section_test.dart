import 'dart:convert';

import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/git/presentation/worktree_setup_page.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/cleanup.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// The cleanup section: the setting is a preference this page writes; the
/// preview and the sweep are the server's, scripted here — the page is under
/// test, not the rules (`server/test/git/`).
void main() {
  late FakeDataServer server;
  late ProviderContainer container;

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

  setUp(() async {
    server = FakeDataServer(clock: () => testTime);
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    final clock = FixedClock(testTime);
    server.gitWork.cleanupReport = WorktreeCleanupReport(
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
      );
    final data = await server.override();
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(),
        data,
        clockProvider.overrideWithValue(clock),
      ],
    );
  });
  tearDown(() => container.dispose());

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

  WorktreeCleanupSettings stored() => WorktreeCleanupSettings.fromJson(
    switch (server.preferences[WorktreeCleanupKeys.settings]) {
      final String raw => jsonDecode(raw),
      null => null,
    },
  );

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

      expect(
        server.gitWork.asked.whereType<WorktreeCleanupPreview>(),
        hasLength(1),
      );
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
