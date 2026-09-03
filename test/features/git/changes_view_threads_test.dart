import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/git/application/changes_service.dart';
import 'package:karmashala/src/features/git/domain/file_change.dart';
import 'package:karmashala/src/features/git/domain/review_thread.dart';
import 'package:karmashala/src/features/git/presentation/changes_view.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_actions.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/sessions/domain/session_delivery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import 'review_thread_harness.dart';

/// What the Changes panel draws once a comment is a thread.
///
/// The interesting case is the second one. A thread whose file has changed must
/// not be drawn beside a line — the line it names is not the line it was
/// written about any more — and must not vanish either. The implementation this
/// replaces did the first of those silently: the marker stayed on row 2 of a
/// diff whose row 2 was now different code.
void main() {
  // New-file line numbers for these rows: the hunk header carries none, then
  // 1, none (a removed line is not in the new file), 2, 3.
  const diff =
      '@@ -1,3 +1,3 @@\n final a = 1;\n-final b = 2;\n+final b = 3;\n final c = 4;\n';
  const comment = 'Use the configured value.';

  final sent = <String>[];

  setUp(sent.clear);

  Future<void> pump(WidgetTester tester, ReviewThreadHarness harness) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          selectedSessionIdProvider.overrideWith(_FixedSession.new),
          sessionActionsProvider.overrideWith(
            (ref) => _RecordingActions(ref, sent),
          ),
          databaseProvider.overrideWithValue(harness.db),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          idGeneratorProvider.overrideWithValue(
            SequentialIdGenerator('scope-thread-'),
          ),
          changesServiceProvider.overrideWithValue(
            ChangesService(
              runnerFactory: FakeCommandRunnerFactory(
                fallback: FakeCommandRunner(
                  responder: (request) => _hashObject(request, harness.shas),
                ),
              ),
              environmentDao: ExecutionEnvironmentDao(harness.db),
            ),
          ),
          repositoryChangesProvider.overrideWith(
            (ref) async => const [
              FileChange(
                path: 'lib/a.dart',
                type: FileChangeType.modified,
                staged: false,
                unstaged: true,
              ),
            ],
          ),
          recentCommitsProvider.overrideWith((ref) async => const []),
          // No worktrees, so the header's picker draws nothing and no
          // `git worktree list` is started for a fixture repository.
          repoWorktreesProvider.overrideWith((ref) async => const []),
          selectedRepositoryIdProvider.overrideWith(_FixedRepository.new),
          repositoryDeliveryProvider.overrideWith(
            (ref, _) async => SessionDelivery.unknown,
          ),
          fileDiffByPathProvider('lib/a.dart').overrideWith((ref) async => diff),
        ],
        child: const MaterialApp(
          home: Scaffold(body: ChangesView(repositoryName: 'app')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('lib/a.dart'));
    await tester.pumpAndSettle();
  }

  testWidgets('an attached thread hangs off the line it was written on', (
    tester,
  ) async {
    final harness = ReviewThreadHarness(shas: {'lib/a.dart': 'sha-one'});
    addTearDown(harness.dispose);
    await harness.service.open(
      repositoryId: 'r1',
      path: 'lib/a.dart',
      body: comment,
      author: 'the user',
      authorKind: ReviewAuthorKind.user,
      startLine: 2,
      excerpt: '+final b = 3;',
    );

    await pump(tester, harness);

    // The comment button on that row wears the comment as its tooltip.
    expect(find.byTooltip(comment), findsOneWidget);
    // Nothing above the diff: an attached thread has a line to live on.
    expect(find.textContaining('Detached'), findsNothing);
  });

  testWidgets('a thread whose file changed leaves the line and says why', (
    tester,
  ) async {
    final harness = ReviewThreadHarness(shas: {'lib/a.dart': 'sha-one'});
    addTearDown(harness.dispose);
    await harness.service.open(
      repositoryId: 'r1',
      path: 'lib/a.dart',
      body: comment,
      author: 'the user',
      authorKind: ReviewAuthorKind.user,
      startLine: 2,
      excerpt: '+final b = 3;',
    );
    // The agent edits the file the comment was written against. The diff on
    // screen is unchanged — which is exactly the trap: row 2 still exists, so a
    // row-indexed marker would still be drawn there, pointing at code nobody
    // commented on.
    harness.shas['lib/a.dart'] = 'sha-two';

    await pump(tester, harness);

    expect(
      find.byTooltip(comment),
      findsNothing,
      reason: 'a detached thread must not be drawn against a current line',
    );
    // Still there, with the reason spelled out and the comment readable.
    expect(find.textContaining('Detached'), findsOneWidget);
    expect(find.text(comment), findsOneWidget);
  });

  testWidgets('a file-level thread is shown above the diff, not lost', (
    tester,
  ) async {
    final harness = ReviewThreadHarness(shas: {'lib/a.dart': 'sha-one'});
    addTearDown(harness.dispose);
    await harness.service.open(
      repositoryId: 'r1',
      path: 'lib/a.dart',
      body: 'This whole file belongs in the other package.',
      author: 'the user',
      authorKind: ReviewAuthorKind.user,
    );

    await pump(tester, harness);

    expect(
      find.text('This whole file belongs in the other package.'),
      findsOneWidget,
    );
    // Attached — the file has not changed — so no detachment notice.
    expect(find.textContaining('Detached'), findsNothing);
  });

  testWidgets('sending gathers the pending set and clears nothing', (
    tester,
  ) async {
    final harness = ReviewThreadHarness(shas: {'lib/a.dart': 'sha-one'});
    addTearDown(harness.dispose);
    final wanted = await harness.service.open(
      repositoryId: 'r1',
      path: 'lib/a.dart',
      body: comment,
      author: 'the user',
      authorKind: ReviewAuthorKind.user,
      startLine: 2,
      excerpt: '+final b = 3;',
    );
    final untriaged = await harness.service.open(
      repositoryId: 'r1',
      path: 'lib/a.dart',
      body: 'A reviewer thought this looked odd.',
      author: 'an agent',
      authorKind: ReviewAuthorKind.agent,
      startLine: 3,
      excerpt: ' final c = 4;',
    );
    expect(wanted.status, ReviewThreadStatus.shouldFix);
    expect(untriaged.status, ReviewThreadStatus.open);

    await pump(tester, harness);
    await tester.tap(find.byTooltip(_sendTooltip));
    await tester.pumpAndSettle();

    // Only the triaged one travels; the agent's untriaged claim does not.
    expect(sent, hasLength(1));
    expect(sent.single, contains(comment));
    expect(sent.single, isNot(contains('A reviewer thought this looked odd.')));

    // And afterwards everything is still there, in the state it was in. The
    // implementation this replaces cleared every annotation in the repository
    // the moment one prompt went out.
    final after = await harness.service.indexFor('r1');
    expect(after.all, hasLength(2));
    expect(after.pending, hasLength(1));
    expect(after.pending.single.thread.status, ReviewThreadStatus.shouldFix);
    expect(find.byTooltip(comment), findsOneWidget);
  });
}

/// The tooltip the send button wears when exactly one thread is pending.
const _sendTooltip =
    'Send 1 should-fix review comments to the agent';

/// A session is selected, so the send button is enabled.
class _FixedSession extends SelectedSessionController {
  @override
  String? build() => 's1';
}

/// Captures what would have been typed into the agent.
class _RecordingActions extends SessionActions {
  _RecordingActions(super.ref, this._sent);

  final List<String> _sent;

  @override
  Future<void> continueSession(String sessionId, String text) async =>
      _sent.add(text);
}

CommandResult _hashObject(CommandRequest request, Map<String, String> shas) {
  if (!request.arguments.contains('hash-object')) {
    return const CommandResult(exitCode: 0, stdout: '', stderr: '');
  }
  final paths = request.arguments.sublist(request.arguments.indexOf('--') + 1);
  final out = <String>[];
  for (final path in paths) {
    final sha = shas[path];
    if (sha == null) {
      return const CommandResult(exitCode: 128, stdout: '', stderr: 'fatal');
    }
    out.add(sha);
  }
  return CommandResult(exitCode: 0, stdout: '${out.join('\n')}\n', stderr: '');
}

/// The Changes panel needs a selected repository to have anything to read.
class _FixedRepository extends SelectedRepositoryController {
  @override
  String? build() => 'r1';
}
