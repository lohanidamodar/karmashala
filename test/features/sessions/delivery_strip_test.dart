import 'dart:async';

import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/util/clock_provider.dart';
import 'package:chitragupta/src/features/agents/data/agent_installation_dao.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/environments/domain/environment_path.dart';
import 'package:chitragupta/src/features/git/application/remote_links.dart';
import 'package:chitragupta/src/features/github/domain/pull_request_snapshot.dart';
import 'package:chitragupta/src/features/projects/data/project_dao.dart';
import 'package:chitragupta/src/features/repositories/data/repository_dao.dart';
import 'package:chitragupta/src/features/sessions/application/delivery_providers.dart';
import 'package:chitragupta/src/features/sessions/application/session_actions.dart';
import 'package:chitragupta/src/features/sessions/application/session_archive_service.dart';
import 'package:chitragupta/src/features/sessions/application/session_handoff_service.dart';
import 'package:chitragupta/src/features/sessions/data/session_dao.dart';
import 'package:chitragupta/src/features/sessions/domain/delivery_action.dart';
import 'package:chitragupta/src/features/sessions/domain/session.dart';
import 'package:chitragupta/src/features/sessions/domain/session_delivery.dart';
import 'package:chitragupta/src/features/sessions/domain/session_fork.dart';
import 'package:chitragupta/src/features/sessions/domain/session_status.dart';
import 'package:chitragupta/src/features/sessions/presentation/delivery_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// The delivery strip.
///
/// The assertion that matters most is the one Loop 33 wrote first: a button
/// that hands work to the agent is a **message**, so the test is on the text
/// that was sent, not on a git call that never happens. What changed is that
/// the app now owns three actions of its own, and those must behave like
/// operations — a link that opens, and an archive that asks first.
class _Recorder {
  final sent = <String>[];
  final opened = <String>[];
  final archived = <({String sessionId, bool discardUncommitted})>[];
  Object? throwOnSend;
  ArchiveOutcome outcome = const ArchiveOutcome.archived();
}

class _RecordingActions extends SessionActions {
  _RecordingActions(super.ref, this._recorder);
  final _Recorder _recorder;

  @override
  Future<void> continueSession(String sessionId, String text) async {
    final failure = _recorder.throwOnSend;
    if (failure != null) throw failure;
    _recorder.sent.add(text);
  }
}

class _RecordingArchive extends SessionArchiveService {
  _RecordingArchive(super.ref, this._recorder);
  final _Recorder _recorder;

  @override
  Future<ArchiveOutcome> archive(
    String sessionId, {
    bool discardUncommitted = false,
  }) async {
    _recorder.archived.add((
      sessionId: sessionId,
      discardUncommitted: discardUncommitted,
    ));
    return _recorder.outcome;
  }
}

void main() {
  late _Recorder recorder;
  late AppDatabase db;

  const worktree = EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\src\.chitragupta-worktrees\app-s1',
  );

  setUp(() {
    recorder = _Recorder();
    db = AppDatabase.memory();
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
        worktree: worktree,
        status: SessionStatus.idle,
        createdAt: testTime,
      ),
    );
  });
  tearDown(() => db.close());

  /// Nowhere to continue to: these tests are about the delivery actions, and
  /// "Continue with…" is not one of them.
  final noContinuation = SessionContinuation(
    targets: const [],
    plan: SessionForkPlan.decide(descriptor: null, agentName: 'Test CLI'),
  );

  Future<void> pump(
    WidgetTester tester,
    SessionDelivery delivery, {
    bool hostedOnTerminal = false,
  }) async {
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...fakeTerminalOverrides(database: db),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          sessionDeliveryProvider.overrideWith((ref, _) async => delivery),
          sessionContinuationProvider.overrideWith((ref, _) => noContinuation),
          sessionActionsProvider.overrideWith(
            (ref) => _RecordingActions(ref, recorder),
          ),
          sessionArchiveServiceProvider.overrideWith(
            (ref) => _RecordingArchive(ref, recorder),
          ),
          openExternalUrlProvider.overrideWithValue((url) async {
            recorder.opened.add(url);
            return true;
          }),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: DeliveryStrip(
              sessionId: 's1',
              hostedOnTerminal: hostedOnTerminal,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The state line on its own — what the session bar hosts above the actions.
  Future<void> pumpStateLine(
    WidgetTester tester,
    SessionDelivery? delivery,
  ) async {
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...fakeTerminalOverrides(database: db),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          sessionDeliveryProvider.overrideWith(
            // No answer yet is the same as no answer at all here: the line
            // draws only what the probes established.
            (ref, _) =>
                delivery == null ? Completer<SessionDelivery>().future : Future.value(delivery),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: DeliveryStateLine(sessionId: 's1')),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  const openPr = PullRequestSnapshot(
    number: 12,
    state: PullRequestState.open,
    title: 'Fix the login',
    url: 'https://github.com/o/r/pull/12',
    mergeable: true,
  );

  testWidgets('shows the stage, the branch and the numbers behind it', (
    tester,
  ) async {
    await pump(
      tester,
      const SessionDelivery(
        branch: 'work',
        baseBranch: 'origin/main',
        hasRemote: true,
        dirtyFiles: 2,
        aheadOfBase: 3,
        hasWorktree: true,
      ),
    );

    expect(find.text('Working'), findsOneWidget);
    expect(find.text('work'), findsOneWidget);
    expect(find.text('2 uncommitted'), findsOneWidget);
    expect(find.text('3 ahead of origin/main'), findsOneWidget);
  });

  group('the two hosts', () {
    const state = SessionDelivery(
      branch: 'work',
      baseBranch: 'origin/main',
      hasRemote: true,
      dirtyFiles: 2,
      aheadOfBase: 3,
      hasWorktree: true,
    );

    testWidgets('above the composer the strip still carries its own facts', (
      tester,
    ) async {
      // Unchanged, and asserted so: the conversation's host is a rule, a state
      // line and a row of Material chips, and the session bar's redesign is
      // not allowed to leak into it.
      await pump(tester, state);

      expect(find.byType(Divider), findsOneWidget);
      expect(find.text('Working'), findsOneWidget);
      expect(find.widgetWithText(ActionChip, 'Commit'), findsOneWidget);
      expect(
        tester.getCenter(find.text('Working')).dy,
        lessThan(tester.getCenter(find.text('Commit')).dy),
        reason: 'the state line is above the chips, as it always was',
      );
    });

    testWidgets('under the terminal the strip is the actions and nothing else', (
      tester,
    ) async {
      // The facts are drawn by the bar, above this, so drawing them here too
      // would be the second copy that eventually disagrees with the first.
      await pump(tester, state, hostedOnTerminal: true);

      expect(find.text('Commit'), findsOneWidget);
      expect(find.text('Working'), findsNothing);
      expect(find.text('work'), findsNothing);
      expect(find.text('2 uncommitted'), findsNothing);
      expect(
        find.byType(ActionChip),
        findsNothing,
        reason: 'the bar draws its own control, not a message-column chip',
      );
      expect(find.byType(Divider), findsNothing, reason: 'the bar draws it');
    });

    testWidgets('the state line stands on its own for the bar to place', (
      tester,
    ) async {
      await pumpStateLine(tester, state);

      expect(find.text('Working'), findsOneWidget);
      expect(find.text('work'), findsOneWidget);
      expect(find.text('3 ahead of origin/main'), findsOneWidget);
      expect(find.text('Commit'), findsNothing, reason: 'facts only');
    });

    testWidgets('and draws nothing at all until something is known', (
      tester,
    ) async {
      // Its own emptiness, so the bar reserves no room for a line that has
      // nothing to say.
      await pumpStateLine(tester, null);
      expect(tester.getSize(find.byType(DeliveryStateLine)), Size.zero);
    });
  });

  testWidgets('a prompt action sends its text verbatim, with no dialog', (
    tester,
  ) async {
    await pump(
      tester,
      const SessionDelivery(branch: 'work', hasRemote: true, dirtyFiles: 1),
    );

    await tester.tap(find.text('Commit'));
    await tester.pumpAndSettle();

    expect(recorder.sent, [DeliveryAction.commit.prompt]);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('the next action follows the stage', (tester) async {
    await pump(
      tester,
      const SessionDelivery(
        branch: 'work',
        hasRemote: true,
        upstream: 'origin/work',
        dirtyFiles: 0,
        aheadOfBase: 2,
        unpushed: 0,
      ),
    );
    expect(find.text('Pushed'), findsOneWidget);
    expect(find.text('Open PR'), findsOneWidget);
  });

  testWidgets('a failure that means the prompt never left shows a snackbar', (
    tester,
  ) async {
    await pump(tester, const SessionDelivery(hasRemote: true));
    recorder.throwOnSend = StateError('The agent for this session is gone.');

    await tester.tap(find.text('Commit'));
    await tester.pumpAndSettle();

    expect(find.text('The agent for this session is gone.'), findsOneWidget);
    expect(recorder.sent, isEmpty);
  });

  testWidgets(
    'the pull request number and its checks open pages, not prompts',
    (tester) async {
      await pump(
        tester,
        const SessionDelivery(
          branch: 'work',
          hasRemote: true,
          dirtyFiles: 0,
          pullRequest: PullRequestSnapshot(
            number: 12,
            state: PullRequestState.open,
            url: 'https://github.com/o/r/pull/12',
            mergeable: true,
            checks: ChecksSummary(passed: 2),
          ),
        ),
      );

      await tester.tap(find.text('#12'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Checks'));
      await tester.pumpAndSettle();

      expect(recorder.opened, [
        'https://github.com/o/r/pull/12',
        'https://github.com/o/r/pull/12/checks',
      ]);
      expect(recorder.sent, isEmpty);
    },
  );

  testWidgets('merge is a prompt like the rest — the agent runs gh', (
    tester,
  ) async {
    await pump(
      tester,
      const SessionDelivery(
        hasRemote: true,
        dirtyFiles: 0,
        pullRequest: PullRequestSnapshot(
          number: 12,
          state: PullRequestState.open,
          url: 'https://github.com/o/r/pull/12',
          mergeable: true,
          checks: ChecksSummary(passed: 1),
        ),
      ),
    );

    await tester.tap(find.text('Merge'));
    await tester.pumpAndSettle();
    expect(recorder.sent, [DeliveryAction.merge.prompt]);
  });

  testWidgets('a blocked step is drawn, disabled, with its reason', (
    tester,
  ) async {
    await pump(
      tester,
      const SessionDelivery(
        hasRemote: true,
        dirtyFiles: 0,
        pullRequest: PullRequestSnapshot(
          number: 12,
          state: PullRequestState.open,
          url: 'https://github.com/o/r/pull/12',
          mergeable: true,
          checks: ChecksSummary(passed: 1),
          reviewDecision: ReviewDecision.changesRequested,
        ),
      ),
    );

    expect(find.text('Merge'), findsOneWidget);
    await tester.tap(find.text('Merge'));
    await tester.pumpAndSettle();
    expect(recorder.sent, isEmpty, reason: 'the chip is disabled');

    final tooltip = tester.widget<Tooltip>(
      find.ancestor(of: find.text('Merge'), matching: find.byType(Tooltip)),
    );
    expect(tooltip.message, 'A reviewer asked for changes.');
  });

  group('archiving', () {
    Future<void> pumpMerged(WidgetTester tester) => pump(
      tester,
      const SessionDelivery(
        hasRemote: true,
        dirtyFiles: 0,
        hasWorktree: true,
        pullRequest: PullRequestSnapshot(
          number: 12,
          state: PullRequestState.merged,
          url: 'https://github.com/o/r/pull/12',
        ),
      ),
    );

    testWidgets('asks first, and says what is kept', (tester) async {
      await pumpMerged(tester);
      await tester.tap(find.text('Archive worktree'));
      await tester.pumpAndSettle();

      expect(find.text('Archive this worktree?'), findsOneWidget);
      expect(
        find.textContaining(
          'transcript, review notes and checkpoints are kept',
        ),
        findsOneWidget,
      );
      expect(recorder.archived, isEmpty, reason: 'nothing until confirmed');

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(recorder.archived, isEmpty);
    });

    testWidgets('a confirmed archive runs, and reports what it did', (
      tester,
    ) async {
      await pumpMerged(tester);
      await tester.tap(find.text('Archive worktree'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Archive'));
      await tester.pumpAndSettle();

      expect(recorder.archived, [(sessionId: 's1', discardUncommitted: false)]);
      expect(find.text('Worktree archived.'), findsOneWidget);
    });

    testWidgets('uncommitted work is a second, separate confirmation', (
      tester,
    ) async {
      recorder.outcome = const ArchiveOutcome.refused(
        ArchiveRefusal.uncommittedChanges,
      );
      await pumpMerged(tester);
      await tester.tap(find.text('Archive worktree'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Archive'));
      await tester.pumpAndSettle();

      expect(find.text('Discard uncommitted work?'), findsOneWidget);
      recorder.outcome = const ArchiveOutcome.archived();
      await tester.tap(find.text('Discard and archive'));
      await tester.pumpAndSettle();

      expect(recorder.archived.last, (
        sessionId: 's1',
        discardUncommitted: true,
      ));
    });

    testWidgets('declining the second question leaves the worktree alone', (
      tester,
    ) async {
      recorder.outcome = const ArchiveOutcome.refused(
        ArchiveRefusal.uncommittedChanges,
      );
      await pumpMerged(tester);
      await tester.tap(find.text('Archive worktree'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Archive'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(recorder.archived, hasLength(1));
      expect(recorder.archived.single.discardUncommitted, isFalse);
    });
  });

  testWidgets('an archived session offers links but no prompts', (
    tester,
  ) async {
    await pump(
      tester,
      const SessionDelivery(
        archived: true,
        hasWorktree: true,
        hasRemote: true,
        pullRequest: openPr,
      ),
    );

    expect(find.text('Archived'), findsOneWidget);
    expect(find.text('Commit'), findsNothing);
    expect(find.text('Run tests'), findsNothing);
    expect(find.text('Archive worktree'), findsNothing);
    expect(find.text('View PR'), findsOneWidget);
  });
}
