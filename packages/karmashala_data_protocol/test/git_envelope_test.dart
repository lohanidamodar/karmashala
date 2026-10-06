import 'dart:convert';

import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/cleanup.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_git/github.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:test/test.dart';

/// The git a client asks the server to do (slice 3b) — a checkout's reads and
/// writes, worktrees and their cleanup, a project's folders, GitHub — and the
/// changes it tells, through the envelope as JSON text.
void main() {
  const at = CheckoutRef.at(
    EnvironmentPath(environmentId: 'wsl:Ubuntu', path: '/home/me/app'),
  );
  const byId = CheckoutRef.repository('r1');
  const path = EnvironmentPath(environmentId: 'local', path: '/src/app');
  final when = DateTime.utc(2026, 9, 27, 9);

  Map<String, Object?> overTheWire(Map<String, Object?> json) =>
      (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

  R roundTrip<R>(DataRequest<R> request, R result) => DataEnvelope.readAnswer(
    overTheWire(
      DataEnvelope.answer(4, request, DataReply(result, 9, const [])),
    ),
    request,
  ).value;

  final requests = <GitWorkRequest<Object?>>[
    const GitStatusOf(at),
    const GitChangesOf(byId),
    const GitFileDiffStats(at),
    const GitDiff(at, path: 'a.dart', staged: true, base: 'HEAD'),
    const GitDiff(at),
    const GitDiffUntracked(at, 'new.txt'),
    const GitLog(at, limit: 8),
    const GitBranch(at),
    const GitHead(at),
    const GitRevParse(at, 'refs/heads/x'),
    const GitAheadBehind(at, base: 'origin/main'),
    const GitRemoteBranchesContaining(at, 'HEAD'),
    const GitOriginFacts(at),
    const GitMergeInProgress(at),
    const GitBlobShas(at, ['a.dart', 'b.dart']),
    const GitPresenceOf([path]),
    const GitDelivery(at, repository: path),
    const GitDelivery(at),
    const GitStage(at, []),
    const GitStage(at, ['a.dart']),
    const GitUnstage(at, ['a.dart']),
    const GitDiscard(at, tracked: ['a'], untracked: ['b']),
    const GitCommitStaged(at, 'fix it', all: true),
    const GitFetch(at),
    const GitPull(at, rebase: true),
    const GitPush(at, remote: 'origin', branch: 'work'),
    const GitPush(at),
    const GitMerge(at, 'session/s1', commit: true),
    const GitAbortMerge(at),
    const GitMoveBranch(at, branch: 'main', sha: 'abc'),
    const WorktreesOf(at),
    const WorktreeLabels(['r1', 'r2']),
    const WorktreeCreate(
      at,
      creationId: 'c1',
      worktreeName: 'app-s1',
      branch: 'session/s1',
      baseRef: 'origin/main',
      launchesAgent: true,
    ),
    const WorktreeCreate(
      byId,
      creationId: 'c2',
      worktreeName: 'n',
      branch: 'b',
    ),
    const WorktreeCreationCancel('c1'),
    const WorktreeAgentSettled('c1', error: 'no such agent'),
    const WorktreeAgentSettled('c1'),
    const WorktreeRemove(at, worktree: path, force: true),
    const WorktreeCleanupPreview(),
    const WorktreeCleanupSweep(),
    const WorktreeCleanupLogRead(),
    const ProjectFoldersCreate(
      projectName: 'Demo',
      root: path,
      gitUrl: 'git@github.com:o/r.git',
      workspaceId: 'w1',
    ),
    const ProjectRescan('p1'),
    const ProjectMove(
      'p1',
      projectName: 'Renamed',
      root: path,
      defaultRepositoryId: 'r1',
    ),
    const ProjectMove('p1', clearDefaultRepository: true),
    const GitHubOverviewOf(at),
    const GitHubPullRequest(at, branch: 'work'),
    const GitHubMarkReady(at, number: 7),
    const GitHubCreatePr(at, title: 'Fix', body: 'Because'),
  ];

  test('every request round-trips with its arguments', () {
    for (final request in requests) {
      final read = DataEnvelope.readRequest(
        overTheWire(DataEnvelope.request(3, request)),
      );
      expect(read.refusal, isNull, reason: request.kind);
      expect(read.request, isA<GitWorkRequest<Object?>>());
      expect(read.request!.kind, request.kind);
      expect(
        read.request!.argumentsToJson(),
        request.argumentsToJson(),
        reason: request.kind,
      );
    }
  });

  test('every kind is read back as its own request, not another domain\'s', () {
    for (final request in requests) {
      expect(
        DataRequest.fromJson(
          request.kind,
          request.argumentsToJson(),
        ).runtimeType,
        request.runtimeType,
        reason: request.kind,
      );
    }
  });

  test('a checkout is named by id or by where it is, never both', () {
    expect(CheckoutRef.fromJson(byId.toJson()), byId);
    expect(CheckoutRef.fromJson(at.toJson()), at);
    expect(at.toJson().containsKey('repositoryId'), isFalse);
    expect(
      () => DataRequest.fromJson('git.status', {'checkout': 7}),
      throwsA(isA<DataRefused>()),
    );
  });

  test('reads answer typed results', () {
    const change = FileChange(
      path: 'a.dart',
      type: FileChangeType.conflicted,
      staged: false,
      unstaged: true,
      originalPath: 'old.dart',
      conflict: MergeConflict.bothModified,
    );
    final status = roundTrip(
      const GitStatusOf(at),
      const WorkingTreeStatus(
        branch: 'work',
        upstream: 'origin/work',
        aheadOfUpstream: 2,
        behindUpstream: 0,
        changes: [change],
      ),
    );
    expect(status.branch, 'work');
    expect(status.upstream, 'origin/work');
    expect((status.aheadOfUpstream, status.behindUpstream), (2, 0));
    expect(status.changes.single, change);
    expect(roundTrip(const GitChangesOf(at), [change]).single, change);
    const newFolder = [
      FileChange(
        path: 'gen/a.txt',
        type: FileChangeType.untracked,
        staged: false,
        unstaged: true,
        newFolder: 'gen',
      ),
      FileChange(
        path: 'gen/',
        type: FileChangeType.untracked,
        staged: false,
        unstaged: true,
        newFolder: 'gen',
        moreFiles: 4,
      ),
    ];
    expect(roundTrip(const GitChangesOf(at), newFolder), newFolder);
    expect(
      roundTrip(const GitFileDiffStats(at), {
        'a': const FileDiffStat(added: 3, removed: 1),
        'bin': FileDiffStat.binary,
      }),
      {
        'a': const FileDiffStat(added: 3, removed: 1),
        'bin': FileDiffStat.binary,
      },
    );
    expect(roundTrip(const GitDiff(at), 'diff --git a b'), 'diff --git a b');
    expect(
      roundTrip(const GitLog(at), const [
        GitCommit(sha: 'abc1234def', author: 'me', subject: 'fix'),
      ]).single,
      const GitCommit(sha: 'abc1234def', author: 'me', subject: 'fix'),
    );
    expect(roundTrip(const GitBranch(at), null), isNull);
    expect(roundTrip(const GitHead(at), 'main'), 'main');
    expect(
      roundTrip(
        const GitAheadBehind(at, base: 'main'),
        const AheadBehind(ahead: 1, behind: 2),
      ),
      const AheadBehind(ahead: 1, behind: 2),
    );
    expect(roundTrip(const GitAheadBehind(at, base: 'main'), null), isNull);
    expect(
      roundTrip(const GitRemoteBranchesContaining(at, 'HEAD'), null),
      isNull,
    );
    expect(
      roundTrip(const GitRemoteBranchesContaining(at, 'HEAD'), ['origin/x']),
      ['origin/x'],
    );
    expect(
      roundTrip(
        const GitOriginFacts(at),
        const RepositoryOrigin(url: 'git@h:o/r.git', head: 'origin/main'),
      ),
      const RepositoryOrigin(url: 'git@h:o/r.git', head: 'origin/main'),
    );
    expect(roundTrip(const GitMergeInProgress(at), null), isNull);
    expect(roundTrip(const GitBlobShas(at, ['a']), {'a': 'sha'}), {'a': 'sha'});
    expect(
      roundTrip(const GitPresenceOf([path, path]), [
        GitPresence.notARepository,
        GitPresence.unknown,
      ]),
      [GitPresence.notARepository, GitPresence.unknown],
    );
  });

  test('a delivery reading keeps its local half, the page parsed', () {
    final back = roundTrip(
      const GitDelivery(at),
      SessionDelivery(
        branch: 'work',
        baseBranch: 'origin/main',
        upstream: 'origin/work',
        hasRemote: true,
        remote: RemoteRepo.parse('git@github.com:o/r.git'),
        defaultBranch: 'main',
        dirtyFiles: 3,
        lines: const DiffStat(added: 5, removed: 2, files: 2, binaryFiles: 1),
        aheadOfBase: 4,
        behindBase: 1,
        unpushed: 2,
      ),
    );
    expect(back.branch, 'work');
    expect(back.baseBranch, 'origin/main');
    expect(back.upstream, 'origin/work');
    expect(back.hasRemote, isTrue);
    expect(back.remote!.webUrl, 'https://github.com/o/r');
    expect(back.defaultBranch, 'main');
    expect(back.dirtyFiles, 3);
    expect(
      back.lines,
      const DiffStat(added: 5, removed: 2, files: 2, binaryFiles: 1),
    );
    expect((back.aheadOfBase, back.behindBase, back.unpushed), (4, 1, 2));
    final unknown = roundTrip(const GitDelivery(at), SessionDelivery.unknown);
    expect(unknown.branch, isNull);
    expect(unknown.remote, isNull);
    expect(unknown.lines, isNull);
  });

  test('writes answer what they say', () {
    expect(roundTrip(const GitStage(at, []), const DataAck()), isA<DataAck>());
    expect(
      roundTrip(const GitPush(at), 'gitleaks found no secrets.'),
      'gitleaks found no secrets.',
    );
    expect(roundTrip(const GitAbortMerge(at), false), isFalse);
    expect(roundTrip(const WorktreeRemove(at, worktree: path), null), isNull);
    expect(
      roundTrip(const WorktreeRemove(at, worktree: path), 'finished'),
      'finished',
    );
  });

  test('worktrees answer their listing, labels and creation', () {
    const worktree = GitWorktree(
      path: EnvironmentPath(environmentId: 'local', path: '/src/wt'),
      branch: 'session/s1',
      head: 'abc',
    );
    expect(
      roundTrip(const WorktreesOf(at), [
        worktree,
        const GitWorktree(path: path, isBare: true),
        const GitWorktree(path: path, branch: 'gone', isPrunable: true),
      ]),
      [
        worktree,
        const GitWorktree(path: path, isBare: true),
        const GitWorktree(path: path, branch: 'gone', isPrunable: true),
      ],
    );
    expect(
      roundTrip(const WorktreeLabels(['r1']), {
        'r1': const CheckoutLabel(
          isWorktree: true,
          branch: 'b',
          ownerRepositoryId: 'r0',
        ),
      }),
      {
        'r1': const CheckoutLabel(
          isWorktree: true,
          branch: 'b',
          ownerRepositoryId: 'r0',
        ),
      },
    );
    final record = WorktreeCreationRecord.initial().withStage(
      const WorktreeStageStatus(
        stage: WorktreeStage.checkout,
        state: WorktreeStageState.done,
      ),
    );
    final created = roundTrip(
      const WorktreeCreate(
        at,
        creationId: 'c1',
        worktreeName: 'n',
        branch: 'session/s1',
      ),
      CreatedWorktree(worktree: worktree, record: record),
    );
    expect(created.worktree, worktree);
    expect(
      created.record.stage(WorktreeStage.checkout).state,
      WorktreeStageState.done,
    );
  });

  test('cleanup answers its report and its log', () {
    final report = roundTrip(
      const WorktreeCleanupPreview(),
      WorktreeCleanupReport(
        at: when,
        dryRun: true,
        verdicts: const [],
        notes: const ['a note'],
        notInspected: 2,
      ),
    );
    expect(report.at, when);
    expect(report.dryRun, isTrue);
    expect(report.notes, ['a note']);
    expect(report.notInspected, 2);
    final log = roundTrip(
      const WorktreeCleanupLogRead(),
      WorktreeCleanupLog(
        entries: [
          WorktreeCleanupLogEntry(
            at: when,
            projectName: 'Demo',
            worktreePath: '/wt',
            environmentId: 'local',
            rules: const [WorktreeCleanupRule.inactive],
            removed: true,
          ),
        ],
        lastSweep: WorktreeCleanupSweepSummary(startedAt: when, removed: 1),
      ),
    );
    expect(log.entries.single.worktreePath, '/wt');
    expect(log.lastSweep!.removed, 1);
  });

  test('a project\'s folders answer the rows written', () {
    final repository = Repository(
      id: 'r1',
      projectId: 'p1',
      name: 'app',
      path: path,
      createdAt: when,
    );
    final added = roundTrip(const ProjectRescan('p1'), [repository]);
    expect(added.single.id, 'r1');
    expect(added.single.path, path);
    final project = Project(
      id: 'p1',
      name: 'Demo',
      root: path,
      createdAt: when,
    );
    final created = roundTrip(
      const ProjectFoldersCreate(projectName: 'Demo', root: path),
      ProjectCheckouts(project, [repository]),
    );
    expect(created.project.id, 'p1');
    expect(created.repositories.single.id, 'r1');
  });

  test('GitHub answers its page and a branch\'s pull request', () {
    final overview = roundTrip(
      const GitHubOverviewOf(at),
      const GitHubOverview(
        repository: GitHubRepo(
          nameWithOwner: 'o/r',
          url: 'https://github.com/o/r',
          isPrivate: true,
          stargazerCount: 3,
          description: 'd',
          defaultBranch: 'main',
        ),
        pullRequests: [
          PullRequest(number: 1, title: 't', state: 'OPEN', author: 'me'),
        ],
        issues: [Issue(number: 2, title: 'i', state: 'OPEN')],
      ),
    );
    expect(overview.repository!.nameWithOwner, 'o/r');
    expect(overview.repository!.isPrivate, isTrue);
    expect(overview.pullRequests.single.author, 'me');
    expect(overview.issues.single.number, 2);
    expect(
      roundTrip(const GitHubOverviewOf(at), const GitHubOverview()).repository,
      isNull,
    );
    final partial = roundTrip(
      const GitHubOverviewOf(at),
      const GitHubOverview(
        pullRequests: [PullRequest(number: 1, title: 't', state: 'OPEN')],
        issuesFailure: 'the repository has issues switched off',
      ),
    );
    expect(partial.pullRequests.single.number, 1);
    expect(partial.issuesFailure, 'the repository has issues switched off');
    expect(partial.pullRequestsFailure, isNull);

    final reading = roundTrip(
      const GitHubPullRequest(at, branch: 'work'),
      const PullRequestReading(
        pullRequest: PullRequestSnapshot(
          number: 7,
          state: PullRequestState.open,
          title: 'Fix',
          url: 'https://github.com/o/r/pull/7',
          isDraft: true,
          mergeable: false,
          mergeStateStatus: MergeStateStatus.blocked,
          reviewDecision: ReviewDecision.changesRequested,
          unresolvedReviewThreads: 2,
          checks: ChecksSummary(passed: 3, failed: 1, pending: 1, skipped: 1),
          headRefName: 'work',
          baseRefName: 'main',
        ),
        strategies: MergeStrategies(squash: true, rebase: false),
        protection: BranchProtection(
          status: BranchProtectionRead.read,
          branch: 'main',
          requiredApprovals: 2,
          requiresCodeOwnerReview: true,
          requiredChecks: ['ci'],
          requiresLinearHistory: true,
        ),
      ),
    );
    final pr = reading.pullRequest!;
    expect(pr.number, 7);
    expect(pr.state, PullRequestState.open);
    expect(pr.isDraft, isTrue);
    expect(pr.mergeable, isFalse);
    expect(pr.mergeStateStatus, MergeStateStatus.blocked);
    expect(pr.reviewDecision, ReviewDecision.changesRequested);
    expect(pr.unresolvedReviewThreads, 2);
    expect(
      pr.checks,
      const ChecksSummary(passed: 3, failed: 1, pending: 1, skipped: 1),
    );
    expect(pr.baseRefName, 'main');
    expect(
      reading.strategies,
      const MergeStrategies(squash: true, rebase: false),
    );
    expect(reading.protection.status, BranchProtectionRead.read);
    expect(reading.protection.requiredApprovals, 2);
    expect(reading.protection.requiredChecks, ['ci']);
    expect(reading.protection.requiresLinearHistory, isTrue);
    expect(
      roundTrip(
        const GitHubPullRequest(at, branch: 'x'),
        PullRequestReading.none,
      ).pullRequest,
      isNull,
    );
  });

  test('what git work moved is told, and read back', () {
    final record = WorktreeCreationRecord.initial();
    final text = jsonEncode(
      DataEnvelope.changes(
        DataChanges(5, [
          const CheckoutTouched(
            environmentId: 'local',
            path: '/src/app',
            repositoryId: 'r1',
            cause: CheckoutTouchCause.turnEnded,
          ),
          const CheckoutTouched(
            environmentId: 'local',
            path: '/src/other',
            cause: CheckoutTouchCause.worktree,
          ),
          WorktreeCreationChanged('c1', path, record),
          WorktreeCleanupChanged(
            WorktreeCleanupLog(
              lastSweep: WorktreeCleanupSweepSummary(startedAt: when),
            ),
          ),
        ]),
      ),
    );
    final back = DataEnvelope.readChanges(
      (jsonDecode(text) as Map).cast<String, Object?>(),
    );
    expect(back.revision, 5);
    final touched = back.changes[0] as CheckoutTouched;
    expect(touched.directory, path);
    expect(touched.repositoryId, 'r1');
    expect(touched.cause, CheckoutTouchCause.turnEnded);
    final other = back.changes[1] as CheckoutTouched;
    expect(other.repositoryId, isNull);
    expect(other.cause, CheckoutTouchCause.worktree);
    final creation = back.changes[2] as WorktreeCreationChanged;
    expect(creation.creationId, 'c1');
    expect(creation.repo, path);
    expect(creation.record.outcome, record.outcome);
    final cleanup = back.changes[3] as WorktreeCleanupChanged;
    expect(cleanup.log.lastSweep!.startedAt, when);
    expect(back.changes, everyElement(isA<GitChange>()));
  });

  test(
    'cleanup\'s log and last sweep are the server\'s; its setting is not',
    () {
      expect(PreferenceKeys.isReserved(WorktreeCleanupKeys.log), isTrue);
      expect(PreferenceKeys.isReserved(WorktreeCleanupKeys.lastSweep), isTrue);
      expect(PreferenceKeys.isReserved(WorktreeCleanupKeys.settings), isFalse);
    },
  );
}
