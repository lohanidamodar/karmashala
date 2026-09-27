import 'dart:async';

import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/git/presentation/worktree_create_dialog.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_ui/theme.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';

const _repo = EnvironmentPath(environmentId: 'windows', path: r'C:\src\app');

/// **A worktree on its own.**
///
/// The finding this closes: `worktree_create` could make one for an agent, and
/// a person could only get one by launching a session into it — which is
/// backwards for the case the tool exists for, somewhere to try something
/// without disturbing the checkout an agent is already editing. The server
/// makes it (`worktrees.create`); this dialog asks, draws the stages it is
/// told, and cancels.
void main() {
  late FakeDataServer server;

  setUp(() {
    server = FakeDataServer()..environmentRows.upsert(windowsEnv());
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [await server.override()],
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

  /// The creation the dialog asked the server for, or null.
  WorktreeCreate? asked() =>
      server.gitWork.asked.whereType<WorktreeCreate>().firstOrNull;

  WorktreeCreationRecord withCheckout(
    WorktreeStageState state, {
    String? detail,
    String? progress,
    WorktreeCreationOutcome outcome = WorktreeCreationOutcome.running,
    String? cleanup,
  }) {
    final base = WorktreeCreationRecord.initial().withStage(
      WorktreeStageStatus(
        stage: WorktreeStage.checkout,
        state: state,
        detail: detail,
        percent: progress == null ? null : 30,
        progressLabel: progress,
      ),
    );
    return outcome == WorktreeCreationOutcome.running
        ? base
        : base.finish(outcome, cleanup: cleanup);
  }

  testWidgets('a named worktree is asked of the server, with its branch', (
    tester,
  ) async {
    await open(tester);

    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'spike');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    final create = asked()!;
    expect(create.checkout.directory, _repo);
    expect(create.worktreeName, 'spike');
    expect(create.branch, 'spike');
    expect(create.baseRef, isNull);
    expect(create.launchesAgent, isFalse);
  });

  testWidgets('a chosen base ref is passed on; a blank one is not', (
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

    expect(asked()!.branch, 'feat/spike');
    expect(asked()!.baseRef, 'origin/main');
  });

  testWidgets('cancelling creates nothing', (tester) async {
    await open(tester);

    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'spike');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(server.gitWork.asked, isEmpty);
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
    const said = "fatal: a branch named 'spike' already exists";
    server.gitWork.onCreate = (create) async {
      server.gitWork.creationMoved(
        create.creationId,
        _repo,
        withCheckout(
          WorktreeStageState.failed,
          detail: said,
          outcome: WorktreeCreationOutcome.failed,
        ),
      );
      throw const DataRefused(DataRefusalCode.failed, said);
    };
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
      findsWidgets,
    );
    expect(find.text('Checkout · failed'), findsOneWidget);
  });

  testWidgets('a checkout in progress can be cancelled from the dialog', (
    tester,
  ) async {
    final cancelled = Completer<void>();
    server.gitWork.answer = (request) {
      if (request is WorktreeCreationCancel) cancelled.complete();
      return FakeGitWork.unhandled;
    };
    server.gitWork.onCreate = (create) async {
      server.gitWork.creationMoved(
        create.creationId,
        _repo,
        withCheckout(
          WorktreeStageState.running,
          progress: 'Updating files',
        ),
      );
      await cancelled.future;
      server.gitWork.creationMoved(
        create.creationId,
        _repo,
        withCheckout(
          WorktreeStageState.failed,
          detail: 'Cancelled.',
          outcome: WorktreeCreationOutcome.cancelled,
          cleanup: 'Removed the half-made worktree.',
        ),
      );
      throw const DataRefused.invalid(
        'Worktree creation cancelled. Removed the half-made worktree.',
      );
    };
    await open(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'spike');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    // Not settled: a running stage spins for as long as it runs.
    await tester.pump();
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

    expect(cancelled.isCompleted, isTrue);
    expect(find.text('Checkout · failed'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(WorktreeCreationDialog),
        matching: find.textContaining('Removed the half-made worktree'),
      ),
      findsWidgets,
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
