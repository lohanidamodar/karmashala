import 'package:flutter/material.dart';
import 'package:karmashala/src/features/environments/application/environment_resolver.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_store/database.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/git/application/git_providers.dart';
import 'package:karmashala_git/worktrees.dart';
import 'package:karmashala/src/features/git/presentation/worktree_create_dialog.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';
import 'worktree_processes.dart';

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
      processFactory: (_) => finishedGit(),
    );
    service = WorktreeService(
      runnerFactory: FakeCommandRunnerFactory(fallback: runner),
      environmentOf: worktreeEnvironmentOf(envDao),
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
                onPressed: () => showWorktreeCreateDialog(context, ref, _repo),
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
  List<String>? gitArgv() => worktreeAddArgv(runner);

  testWidgets('a named worktree goes through the service the tool uses', (
    tester,
  ) async {
    await open(tester);

    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'spike');
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
      '--no-checkout',
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
    // On the failed stage, which stays up rather than closing on the error.
    expect(
      find.descendant(
        of: find.byType(WorktreeCreationDialog),
        matching: find.textContaining('already exists'),
      ),
      findsOneWidget,
    );
    expect(find.text('Checkout · failed'), findsOneWidget);
  });

  testWidgets('a checkout in progress can be cancelled from the dialog', (
    tester,
  ) async {
    final checkout = FakeProcessHandle();
    runner.processFactory = (_) => checkout;
    await open(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'spike');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    // Not settled: a running stage spins for as long as it runs.
    await tester.pump();
    await tester.pump();
    checkout.emitStderr('Updating files:  30% (3/10)');
    await tester.pump();
    expect(find.textContaining('Updating files 30%'), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byType(WorktreeCreationDialog),
        matching: find.widgetWithText(TextButton, 'Cancel'),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();

    expect(checkout.killed, isTrue);
    expect(find.text('Checkout · failed'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(WorktreeCreationDialog),
        matching: find.textContaining('Removed the half-made worktree'),
      ),
      findsOneWidget,
    );
    expect(
      runner.requests.map((r) => r.arguments.skip(2).take(3).toList()),
      contains(equals(['worktree', 'remove', '--force'])),
    );
    expect(find.widgetWithText(TextButton, 'Close'), findsOneWidget);
  });

  testWidgets('a created worktree closes its progress on its own', (
    tester,
  ) async {
    await open(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'spike');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(find.byType(WorktreeCreationDialog), findsNothing);
    expect(find.textContaining('Created'), findsOneWidget);
  });
}
