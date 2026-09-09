import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/theme/app_theme.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/git/application/git_providers.dart';
import 'package:karmashala/src/features/git/application/worktree_service.dart';
import 'package:karmashala/src/features/git/presentation/worktree_create_dialog.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';

const _repo = EnvironmentPath(environmentId: 'windows', path: r'C:\src\app');

/// **A worktree on its own.**
///
/// The finding this closes: `worktree_create` could make one for an agent, and
/// a person could only get one by launching a session into it — which is
/// backwards for the case the tool exists for, somewhere to try something
/// without disturbing the checkout an agent is already editing.
void main() {
  late AppDatabase db;
  late FakeCommandRunner runner;
  late WorktreeService service;

  setUp(() {
    db = AppDatabase.memory();
    final envDao = ExecutionEnvironmentDao(db)..upsert(windowsEnv());
    runner = FakeCommandRunner(
      responder: (_) =>
          const CommandResult(exitCode: 0, stdout: '', stderr: ''),
    );
    service = WorktreeService(
      runnerFactory: FakeCommandRunnerFactory(fallback: runner),
      environmentDao: envDao,
    );
  });
  tearDown(() => db.close());

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [worktreeServiceProvider.overrideWithValue(service)],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () =>
                    showWorktreeCreateDialog(context, ref, _repo),
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

  /// git's argv for the create, or null when nothing was run.
  List<String>? gitArgv() =>
      runner.requests.isEmpty ? null : runner.requests.last.arguments;

  testWidgets('a named worktree goes through the service the tool uses', (
    tester,
  ) async {
    await open(tester);

    await tester.enterText(
      find.widgetWithText(TextField, 'Name'),
      'spike',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    // The sibling path `WorktreeService` computes, not one this dialog made up
    // — which is what makes it the same worktree the tool creates.
    expect(gitArgv(), [
      '-C',
      r'C:\src\app',
      'worktree',
      'add',
      '-b',
      'spike',
      r'C:\src\.karmashala-worktrees\app-spike',
    ]);
  });

  testWidgets('a chosen base ref is passed to git; a blank one is not', (
    tester,
  ) async {
    await open(tester);

    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'spike');
    await tester.enterText(
      find.widgetWithText(TextField, 'Branch'),
      'feat/spike',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'From (optional)'),
      'origin/main',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(gitArgv(), contains('feat/spike'));
    expect(gitArgv()!.last, 'origin/main');
  });

  testWidgets('cancelling creates nothing', (tester) async {
    await open(tester);

    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'spike');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(runner.requests, isEmpty);
  });

  testWidgets('an unnamed worktree cannot be created', (tester) async {
    await open(tester);

    // Disabled rather than refused after the fact: the name is the folder, and
    // git would answer with something about a path rather than about a name.
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Create'))
          .onPressed,
      isNull,
    );
  });

  testWidgets('git\'s own words survive a failure', (tester) async {
    runner.responder = (_) => const CommandResult(
      exitCode: 128,
      stdout: '',
      stderr: "fatal: a branch named 'spike' already exists",
    );
    await open(tester);

    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'spike');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    // "Could not create worktree" would hide the one thing worth reading.
    expect(find.textContaining('already exists'), findsOneWidget);
  });
}
