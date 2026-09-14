import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/git/application/changes_service.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala/src/features/git/presentation/changes_view.dart';
import 'package:karmashala/src/features/git/presentation/diff_line_tile.dart';
import 'package:karmashala/src/features/git/presentation/diff_view.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_actions.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:karmashala/src/features/repositories/data/repository_dao.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import 'review_thread_harness.dart';

/// What a file's diff draws once a comment is a thread.
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
          fileDiffByPathProvider(
            'lib/a.dart',
          ).overrideWith((ref) async => diff),
        ],
        // The diff is a tab's content now, and the "send" button is still the
        // panel's header — both, so one harness covers both halves.
        child: const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                SizedBox(
                  height: 120,
                  child: ChangesView(repositoryName: 'app'),
                ),
                Expanded(child: FileDiffView(path: 'lib/a.dart')),
              ],
            ),
          ),
        ),
      ),
    );
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

  /// **A diff tab's comments belong to the repository it was opened on.**
  ///
  /// The shipped UI only ever uses this branch — `DiffTabView` hands
  /// `FileDiffView` a checkout and a repository — and it was the one nothing
  /// pumped. Both reads used to follow `selectedRepositoryIdProvider`, so
  /// selecting another repository in the sidebar redrew this tab with that
  /// repository's threads beside this one's lines.
  /// Pumps the branch the shipped UI actually uses: a checkout and a repository
  /// of its own, with the sidebar pointed somewhere else — or nowhere.
  Future<void> pumpTab(
    WidgetTester tester,
    ReviewThreadHarness harness, {
    required String? sidebar,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(harness.db),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          idGeneratorProvider.overrideWithValue(
            SequentialIdGenerator('scope-thread-'),
          ),
          changesServiceProvider.overrideWithValue(
            ChangesService(
              runnerFactory: FakeCommandRunnerFactory(
                fallback: FakeCommandRunner(
                  responder: (request) =>
                      request.arguments.contains('hash-object')
                      ? _hashObject(request, harness.shas)
                      : const CommandResult(
                          exitCode: 0,
                          stdout: diff,
                          stderr: '',
                        ),
                ),
              ),
              environmentDao: ExecutionEnvironmentDao(harness.db),
            ),
          ),
          selectedRepositoryIdProvider.overrideWith(() => _Sidebar(sidebar)),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: FileDiffView(
              path: 'lib/a.dart',
              checkout: EnvironmentPath(
                environmentId: 'windows',
                path: r'C:\src\demo\app',
              ),
              repositoryId: 'r1',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Whether any comment button on the diff can be pressed.
  bool canComment(WidgetTester tester) => tester
      .widgetList<IconButton>(find.byType(IconButton))
      .any((button) => button.onPressed != null);

  /// **A diff tab's comments belong to the repository it was opened on.**
  ///
  /// The shipped UI only ever uses this branch — `DiffTabView` hands
  /// `FileDiffView` a checkout and a repository — and it was the one nothing
  /// pumped. Both reads used to follow `selectedRepositoryIdProvider`, so
  /// selecting another repository in the sidebar redrew this tab with that
  /// repository's threads beside this one's lines, and filed a new comment
  /// against it.
  testWidgets('a tab draws its own repository, not the sidebar\'s', (
    tester,
  ) async {
    final harness = ReviewThreadHarness(shas: {'lib/a.dart': 'sha-one'});
    addTearDown(harness.dispose);
    RepositoryDao(
      harness.db,
    ).insert(repository(id: 'r2', name: 'other', path: r'C:\src\demo\other'));
    await harness.service.open(
      repositoryId: 'r1',
      path: 'lib/a.dart',
      body: comment,
      author: 'the user',
      authorKind: ReviewAuthorKind.user,
      startLine: 2,
      excerpt: '+final b = 3;',
    );
    await harness.service.open(
      repositoryId: 'r2',
      path: 'lib/a.dart',
      body: 'Written against the other repository.',
      author: 'the user',
      authorKind: ReviewAuthorKind.user,
      startLine: 2,
      excerpt: '+final b = 3;',
    );

    await pumpTab(tester, harness, sidebar: 'r2');

    expect(find.byTooltip(comment), findsOneWidget);
    expect(
      find.byTooltip('Written against the other repository.'),
      findsNothing,
    );
  });

  testWidgets('a restored tab can be commented on before anything is '
      'selected', (tester) async {
    // Restore rebuilds a diff tab before the sidebar has picked a repository.
    // The button used to be disabled on a perfectly good diff, with no reason
    // given anywhere.
    final harness = ReviewThreadHarness(shas: {'lib/a.dart': 'sha-one'});
    addTearDown(harness.dispose);

    await pumpTab(tester, harness, sidebar: null);

    expect(find.text('+final b = 3;'), findsOneWidget);
    expect(canComment(tester), isTrue);
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

  testWidgets('diff text sits inside a SelectionArea, so it can be copied', (
    tester,
  ) async {
    final harness = ReviewThreadHarness(shas: {'lib/a.dart': 'sha-one'});
    addTearDown(harness.dispose);
    await pumpTab(tester, harness, sidebar: null);

    // Not merely present: the rows have to be *inside* it, or a drag over the
    // code selects nothing.
    expect(find.byType(SelectionArea), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(SelectionArea),
        matching: find.byType(DiffLineTile),
      ),
      findsWidgets,
    );
  });
}

/// The tooltip the send button wears when exactly one thread is pending.
const _sendTooltip = 'Send 1 should-fix review comments to the agent';

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

/// The sidebar's selection, which a diff tab must not read.
class _Sidebar extends SelectedRepositoryController {
  _Sidebar(this._id);

  final String? _id;

  @override
  String? build() => _id;
}
