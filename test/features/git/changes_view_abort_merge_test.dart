import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/git/application/changes_service.dart';
import 'package:karmashala/src/features/git/domain/git_worktree.dart';
import 'package:karmashala/src/features/git/presentation/changes_view.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/domain/session_delivery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';

/// `git merge --abort`, reachable by hand.
///
/// It had exactly one caller — the delivery pipeline's failure path — so a
/// merge an agent left half-done could only be undone by asking a model to run
/// the command. Merge and push stay prompts; this one is the app's because
/// there is nothing in it to decide.
void main() {
  const repo = EnvironmentPath(environmentId: 'windows', path: r'C:\app');

  late AppDatabase db;
  late FakeCommandRunner runner;

  /// Answers `merge --abort` with [aborted] and every read with nothing.
  ChangesService serviceThatAborts({required bool aborted}) {
    runner = FakeCommandRunner(
      responder: (req) => req.arguments.contains('--abort')
          ? CommandResult(
              exitCode: aborted ? 0 : 128,
              stdout: '',
              stderr: aborted ? '' : 'fatal: There is no merge to abort',
            )
          : const CommandResult(exitCode: 0, stdout: '', stderr: ''),
    );
    return ChangesService(
      runnerFactory: FakeCommandRunnerFactory(fallback: runner),
      environmentDao: ExecutionEnvironmentDao(db),
    );
  }

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
  });
  tearDown(() => db.close());

  Future<void> pump(WidgetTester tester, ChangesService service) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          repoWorktreesProvider.overrideWith((ref) async => const <GitWorktree>[]),
          viewedCheckoutProvider.overrideWithValue(repo),
          repositoryChangesProvider.overrideWith((ref) async => const []),
          recentCommitsProvider.overrideWith((ref) async => const []),
          repositoryDeliveryProvider.overrideWith(
            (ref, _) async => SessionDelivery.unknown,
          ),
          changesServiceProvider.overrideWithValue(service),
        ],
        child: const MaterialApp(
          home: Scaffold(body: ChangesView(repositoryName: 'app')),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the confirm says what is discarded, and cancelling runs nothing',
      (tester) async {
    final service = serviceThatAborts(aborted: true);
    await pump(tester, service);

    await tester.tap(find.byTooltip('Abort merge'));
    await tester.pumpAndSettle();

    expect(find.text('Abort the merge in progress?'), findsOneWidget);
    expect(
      find.textContaining('conflict resolution'),
      findsOneWidget,
      reason: 'the sentence must say what pressing it throws away',
    );

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(runner.requests, isEmpty);
  });

  testWidgets('confirming runs git merge --abort and says the tree is back',
      (tester) async {
    await pump(tester, serviceThatAborts(aborted: true));

    await tester.tap(find.byTooltip('Abort merge'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Abort merge').last);
    await tester.pumpAndSettle();

    expect(runner.requests.single.arguments, ['-C', r'C:\app', 'merge', '--abort']);
    expect(find.textContaining('Merge aborted'), findsOneWidget);
  });

  testWidgets('an abort with no merge to undo says so rather than claiming one',
      (tester) async {
    await pump(tester, serviceThatAborts(aborted: false));

    await tester.tap(find.byTooltip('Abort merge'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Abort merge').last);
    await tester.pumpAndSettle();

    expect(find.textContaining('no merge'), findsOneWidget);
    expect(find.textContaining('Merge aborted'), findsNothing);
  });
}
