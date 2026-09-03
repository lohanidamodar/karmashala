import 'dart:async';

import 'package:karmashala/src/app/theme/app_icons.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';
import 'package:karmashala/src/features/git/application/remote_links.dart';
import 'package:karmashala/src/features/github/domain/merge_strategies.dart';
import 'package:karmashala/src/features/github/domain/pull_request_snapshot.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_actions.dart';
import 'package:karmashala/src/features/sessions/application/delivery_update_service.dart';
import 'package:karmashala/src/features/sessions/application/session_archive_service.dart';
import 'package:karmashala/src/features/sessions/application/session_handoff_service.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala/src/features/sessions/application/session_signals.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/sessions/domain/delivery_action.dart';
import 'package:karmashala/src/features/sessions/domain/session.dart';
import 'package:karmashala/src/features/sessions/domain/session_delivery.dart';
import 'package:karmashala/src/features/sessions/domain/session_fork.dart';
import 'package:karmashala/src/features/sessions/domain/session_status.dart';
import 'package:karmashala/src/features/sessions/presentation/delivery_strip.dart';
import 'package:karmashala/src/features/sessions/presentation/model_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';
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
  final updated = <String>[];
  Object? throwOnSend;
  ArchiveOutcome outcome = const ArchiveOutcome.archived();
  UpdateOutcome updateOutcome = const UpdateOutcome.updated('origin/main');
}

class _RecordingUpdate extends DeliveryUpdateService {
  _RecordingUpdate(super.ref, this._recorder);
  final _Recorder _recorder;

  @override
  Future<UpdateOutcome> updateFromBase(String sessionId) async {
    _recorder.updated.add(sessionId);
    return _recorder.updateOutcome;
  }
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
    path: r'C:\src\.karmashala-worktrees\app-s1',
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
          deliveryUpdateServiceProvider.overrideWith(
            (ref) => _RecordingUpdate(ref, recorder),
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

  testWidgets('being behind and conflicting are facts on the line', (
    tester,
  ) async {
    // The line says what is true; the row below says what to do about it. A
    // line that reports only how far ahead a branch is reads as "up to date"
    // to anyone scanning it, which is the whole reason the counterpart is
    // drawn beside it.
    await pump(
      tester,
      const SessionDelivery(
        branch: 'work',
        baseBranch: 'origin/main',
        hasRemote: true,
        dirtyFiles: 0,
        aheadOfBase: 3,
        behindBase: 4,
        pullRequest: PullRequestSnapshot(
          number: 12,
          state: PullRequestState.open,
          url: 'https://github.com/o/r/pull/12',
          mergeable: false,
        ),
      ),
    );

    expect(find.text('3 ahead of origin/main'), findsOneWidget);
    expect(find.text('4 behind origin/main'), findsOneWidget);
    expect(find.text('conflicts'), findsOneWidget);
  });

  testWidgets('a forge-only BEHIND is drawn without a number', (tester) async {
    // GitHub knows; this clone has fetched nothing since. "0 behind main"
    // would be a contradiction, so the count is dropped and the fact kept.
    await pump(
      tester,
      const SessionDelivery(
        branch: 'work',
        baseBranch: 'origin/main',
        hasRemote: true,
        dirtyFiles: 0,
        behindBase: 0,
        pullRequest: PullRequestSnapshot(
          number: 12,
          state: PullRequestState.open,
          url: 'https://github.com/o/r/pull/12',
          mergeStateStatus: MergeStateStatus.behind,
        ),
      ),
    );

    expect(find.text('behind origin/main'), findsOneWidget);
    expect(find.text('0 behind origin/main'), findsNothing);
  });

  testWidgets('Update is the app doing it, not a sentence to the agent', (
    tester,
  ) async {
    await pump(
      tester,
      const SessionDelivery(
        branch: 'work',
        baseBranch: 'origin/main',
        hasRemote: true,
        dirtyFiles: 0,
        aheadOfBase: 2,
        behindBase: 4,
      ),
    );

    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();

    expect(recorder.updated, ['s1']);
    // The distinction the whole strip is built on: nothing was typed into the
    // session, because there is nothing here for a model to compose.
    expect(recorder.sent, isEmpty);
    // And it reports, because it has no transcript to report into.
    expect(find.text('Updated from origin/main.'), findsOneWidget);
  });

  testWidgets('a refused update says why, and nothing else happens', (
    tester,
  ) async {
    recorder.updateOutcome = const UpdateOutcome.refused(
      UpdateRefusal.conflicted,
      base: 'origin/main',
    );
    await pump(
      tester,
      const SessionDelivery(
        branch: 'work',
        baseBranch: 'origin/main',
        hasRemote: true,
        dirtyFiles: 0,
        aheadOfBase: 2,
        behindBase: 4,
      ),
    );

    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();

    expect(find.textContaining('The merge was undone'), findsOneWidget);
    expect(recorder.sent, isEmpty);
  });

  testWidgets('Resolve conflicts is a prompt — the agent has to decide', (
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
          mergeable: false,
        ),
      ),
    );

    await tester.tap(find.text('Resolve conflicts'));
    await tester.pumpAndSettle();
    expect(recorder.sent, [DeliveryAction.resolveConflicts.prompt]);
  });

  testWidgets('the merge prompt names the strategy the repository allows', (
    tester,
  ) async {
    await pump(
      tester,
      const SessionDelivery(
        hasRemote: true,
        dirtyFiles: 0,
        mergeStrategies: MergeStrategies(
          mergeCommit: false,
          squash: true,
          rebase: false,
        ),
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
    // Not `DeliveryAction.merge.prompt`: the sentence that leaves the app has
    // to be the one the tooltip promised, and that one names a squash.
    expect(recorder.sent, ['Merge the pull request with a squash merge.']);
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

  // ---------------------------------------------------------------------------
  // The model, as a fact rather than a control. See [SessionModelMark].
  // ---------------------------------------------------------------------------

  /// The state line with a container the test can write through, so a model can
  /// be changed the way the app changes it — `SessionLauncher.setModel` — rather
  /// than by rebuilding the tree around a different value.
  ProviderContainer lineContainer({
    SessionDelivery delivery = const SessionDelivery(
      branch: 'session/fix-the-login',
      baseBranch: 'origin/main',
      hasWorktree: true,
    ),
  }) {
    final container = ProviderContainer(
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
        deliveryUpdateServiceProvider.overrideWith(
          (ref) => _RecordingUpdate(ref, recorder),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Widget line(ProviderContainer container, {String sessionId = 's1'}) =>
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(body: DeliveryStateLine(sessionId: sessionId)),
        ),
      );

  /// Everything the mark says on hover. Found through its own glyph, so a
  /// tooltip belonging to the branch link cannot be read by mistake.
  String modelTooltip(WidgetTester tester) => tester
      .widget<Tooltip>(
        find.ancestor(
          of: find.byIcon(AppIcons.robot),
          matching: find.byType(Tooltip),
        ),
      )
      .message!;

  /// A session on [agentId] with [model] recorded against it.
  void seedSession(String id, {required String agentId, String? model}) {
    AgentInstallationDao(
      db,
    ).insert(agentInstallation(id: 'i-$id', agentId: agentId));
    SessionDao(db).insert(
      Session(
        id: id,
        repositoryId: 'r1',
        agentInstallationId: 'i-$id',
        title: 'Session $id',
        useWorktree: false,
        status: SessionStatus.idle,
        createdAt: testTime,
      ),
    );
    if (model != null) SessionDao(db).updateModel(id, model);
  }

  testWidgets('a session that named no model is not given one', (tester) async {
    final container = lineContainer();
    await tester.pumpWidget(line(container));
    await tester.pumpAndSettle();

    // The line is drawn — the branch proves it — and says nothing whatever
    // about a model. No `--model` was passed, so what the agent picked for
    // itself is not something this app knows, and `default` sitting between a
    // stage and a branch would read as an answer to a question nobody asked it.
    expect(find.text('session/fix-the-login'), findsOneWidget);
    expect(find.byIcon(AppIcons.robot), findsNothing);
  });

  testWidgets('the model the launcher resolves is named, and claims no more', (
    tester,
  ) async {
    SessionDao(db).updateModel('s1', 'opus');
    final container = lineContainer();
    await tester.pumpWidget(line(container));
    await tester.pumpAndSettle();

    // The descriptor's label, and the same answer `effectiveModelFor` hands the
    // command line: there is no second resolution here to drift from it.
    expect(find.text('Opus'), findsOneWidget);
    expect(
      container.read(sessionLauncherProvider).effectiveModelFor('s1')!.modelId,
      'opus',
    );

    final tooltip = modelTooltip(tester);
    expect(tooltip, contains('Opus'));
    expect(tooltip, contains('Set for this session'));
    // The refusal, which is the whole reason the mark is shaped this way.
    expect(tooltip, contains('never asked what it is running'));
    expect(tooltip, contains('A /model typed into the terminal'));
    // And nothing on the face that promises liveness — the words the request
    // asked for and the record cannot support.
    expect(find.textContaining('active'), findsNothing);
    expect(find.textContaining('now'), findsNothing);
  });

  testWidgets('an agent that only takes its model at launch says so instead', (
    tester,
  ) async {
    seedSession('s2', agentId: AgentIds.codex, model: 'gpt-5.6-sol');
    final container = lineContainer();
    await tester.pumpWidget(line(container, sessionId: 's2'));
    await tester.pumpAndSettle();

    expect(find.text('GPT-5.6-Sol'), findsOneWidget);
    final tooltip = modelTooltip(tester);
    expect(tooltip, contains('takes its model at launch'));
    expect(tooltip, contains('not true of the process now'));
    // Not the live sentence. Codex's `/model` opens a picker and takes no
    // argument, so telling a Codex user that a typed `/model` goes unseen would
    // send them looking for a live switch that does not exist.
    expect(tooltip, isNot(contains('A /model typed into the terminal')));
  });

  testWidgets('an agent nobody has recorded a model flag for is not named', (
    tester,
  ) async {
    // The row still holds an id — set by an older build, or by hand — and the
    // mark still refuses it: with no descriptor there is no flag to pass, so
    // whatever that CLI is running is not this.
    seedSession('s3', agentId: 'mystery', model: 'something-someone-typed');
    final container = lineContainer();
    await tester.pumpWidget(line(container, sessionId: 's3'));
    await tester.pumpAndSettle();

    expect(find.byIcon(AppIcons.robot), findsNothing);
    expect(find.text('something-someone-typed'), findsNothing);
  });

  testWidgets('a model change repaints the mark and not the line', (
    tester,
  ) async {
    SessionDao(db).updateModel('s1', 'opus');
    final container = lineContainer();
    await tester.pumpWidget(line(container));
    await tester.pumpAndSettle();

    DeliveryStateLine.debugBuildCount = 0;
    SessionModelMark.debugBuildCount = 0;
    // Between two named models, which is exactly what the line's own
    // subscription — the bool "is there a model to name at all" — does not move.
    container.read(sessionLauncherProvider).setModel('s1', 'sonnet');
    await tester.pumpAndSettle();

    expect(find.text('Sonnet'), findsOneWidget);
    expect(SessionModelMark.debugBuildCount, 1);
    expect(
      DeliveryStateLine.debugBuildCount,
      0,
      reason:
          'the stage, the verdict, the branch and the counts know nothing '
          'about a model and must not repaint for one',
    );
  });

  testWidgets('the first model a session is given costs the line one build', (
    tester,
  ) async {
    // The one model signal the line does subscribe to, and it moves at most
    // twice in a session's life. It has to: a `Wrap` charges `spacing` on both
    // sides of a child that drew nothing, so whether there is a mark has to be
    // known before the children are built rather than by the mark itself.
    final container = lineContainer();
    await tester.pumpWidget(line(container));
    await tester.pumpAndSettle();

    DeliveryStateLine.debugBuildCount = 0;
    container.read(sessionLauncherProvider).setModel('s1', 'opus');
    await tester.pumpAndSettle();

    expect(find.text('Opus'), findsOneWidget);
    expect(DeliveryStateLine.debugBuildCount, 1);
  });

  testWidgets('a rename reaches neither the line nor the mark', (tester) async {
    // The CLI store sweep renames rows on a timer, without the user doing
    // anything at all — the narrowing `sessionModelProvider` was written for.
    SessionDao(db).updateModel('s1', 'opus');
    final container = lineContainer();
    await tester.pumpWidget(line(container));
    await tester.pumpAndSettle();

    DeliveryStateLine.debugBuildCount = 0;
    SessionModelMark.debugBuildCount = 0;
    container
        .read(sessionsRevisionProvider.notifier)
        .changed(const SessionChange.renamed('s1'));
    await tester.pumpAndSettle();

    expect(SessionModelMark.debugBuildCount, 0);
    expect(DeliveryStateLine.debugBuildCount, 0);
  });

  testWidgets(
    'a long model name beside a long branch name survives the matrix',
    (tester) async {
      // The two labels in this line whose width nobody can predict, at their
      // worst and together: a model id this build has never heard of (drawn
      // raw, because dropping it would leave the line naming a model the
      // session is not on) beside a branch name of the shape the app's own
      // worktrees make.
      SessionDao(
        db,
      ).updateModel('s1', 'claude-opus-4-6-20260115-extended-thinking');
      final container = lineContainer(
        delivery: const SessionDelivery(
          branch: 'agent/2026-09-03-delivery-strip-model-fact-long-branch-name',
          baseBranch: 'origin/main',
          hasRemote: true,
          dirtyFiles: 2,
          aheadOfBase: 3,
          hasWorktree: true,
        ),
      );

      await expectSurvivesWindowMatrix(
        tester,
        build: () => line(container),
        because:
            'the model is a second unpredictable label in a line that already '
            'had one',
      );
    },
  );

  testWidgets('the facts and the actions still hold together at 720', (
    tester,
  ) async {
    // The session bar's two rows, which is where the risk actually is: this
    // strip's own history is `Commit` stranded up beside the branch name when
    // facts and actions shared one run. They do not share one now, and a fact
    // added above them must not put them back together.
    SessionDao(
      db,
    ).updateModel('s1', 'claude-opus-4-6-20260115-extended-thinking');
    final container = lineContainer(
      delivery: const SessionDelivery(
        branch: 'agent/2026-09-03-delivery-strip-model-fact-long-branch-name',
        baseBranch: 'origin/main',
        hasRemote: true,
        dirtyFiles: 2,
        aheadOfBase: 3,
        hasWorktree: true,
      ),
    );

    await expectSurvivesWindowMatrix(
      tester,
      build: () => UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DeliveryStateLine(sessionId: 's1'),
                  DeliveryStrip(sessionId: 's1', hostedOnTerminal: true),
                ],
              ),
            ),
          ),
        ),
      ),
      because: 'the session bar is a line of facts over a row of controls',
    );
  });
}
