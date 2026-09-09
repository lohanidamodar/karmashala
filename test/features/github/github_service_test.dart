import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';
import 'package:karmashala/src/features/github/data/github_service.dart';
import 'package:karmashala/src/features/github/domain/branch_protection.dart';
import 'package:karmashala/src/features/github/domain/pull_request_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';

void main() {
  const repo = EnvironmentPath(environmentId: 'windows', path: r'C:\app');

  group('mergeStateStatus', () {
    // Every literal here is a value GitHub actually returned for a real pull
    // request; the shapes were taken from `gh pr view --json` against
    // `cli/cli` and `lohanidamodar/karmashala-app` on 2026-09-02.
    PullRequestSnapshot parse(String mergeStateStatus) => parseGhPullRequestView(
      '{"number":1,"state":"OPEN","mergeStateStatus":"$mergeStateStatus"}',
    )!;

    test('BEHIND is read as behind, and nothing else is', () {
      expect(parse('BEHIND').mergeStateStatus, MergeStateStatus.behind);
      expect(parse('BEHIND').isBehindBase, isTrue);
      // BLOCKED masks BEHIND on the wire, so it must not be read as one: the
      // observed case is a PR that is blocked on a required review and may or
      // may not also be behind.
      expect(parse('BLOCKED').isBehindBase, isFalse);
      expect(parse('CLEAN').isBehindBase, isFalse);
    });

    test('DIRTY establishes a conflict on its own', () {
      expect(parse('DIRTY').hasConflict, isTrue);
      expect(parse('CLEAN').hasConflict, isFalse);
    });

    test('UNKNOWN is null, not a value — the same as mergeable', () {
      // GitHub computes this lazily and answers UNKNOWN until it has. Giving
      // that its own enum case would let a caller switch on it as a state of
      // the pull request rather than a state of GitHub's queue.
      expect(parse('UNKNOWN').mergeStateStatus, isNull);
      expect(
        parseGhPullRequestView('{"number":1,"state":"OPEN"}')!.mergeStateStatus,
        isNull,
      );
    });

    test('a conflict still arrives when only mergeable says so', () {
      final pr = parseGhPullRequestView(
        '{"number":1,"state":"OPEN","mergeable":"CONFLICTING"}',
      )!;
      expect(pr.hasConflict, isTrue);
    });
  });

  group('parseForgePolicy', () {
    // The response shape below is the one `gh api graphql` returned for
    // cli/cli#14315 on 2026-09-02, trimmed to the fields asked for.
    const real =
        '{"data":{"repository":{"mergeCommitAllowed":true,'
        '"squashMergeAllowed":true,"rebaseMergeAllowed":true,'
        '"pullRequest":{"reviewThreads":{"totalCount":1,'
        '"nodes":[{"isResolved":true}]}}}}}';

    test('reads the three merge settings and the open threads', () {
      final policy = parseForgePolicy(real);
      expect(policy.strategies.mergeCommit, isTrue);
      expect(policy.strategies.squash, isTrue);
      expect(policy.strategies.rebase, isTrue);
      // One thread, resolved: an answer of zero, not an absence.
      expect(policy.unresolvedReviewThreads, 0);
    });

    test('counts only the unresolved ones', () {
      final policy = parseForgePolicy(
        '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":'
        '[{"isResolved":false},{"isResolved":true},{"isResolved":false}]}}}}}',
      );
      expect(policy.unresolvedReviewThreads, 2);
    });

    test('a squash-only repository reports the other two as false', () {
      final policy = parseForgePolicy(
        '{"data":{"repository":{"mergeCommitAllowed":false,'
        '"squashMergeAllowed":true,"rebaseMergeAllowed":false}}}',
      );
      expect(policy.strategies.preferredLabel, 'squash merge');
      expect(policy.strategies.noneAllowed, isFalse);
      // A definite `false` must survive as a definite `false`. Folding it into
      // the same null that "we did not ask" uses would make a forbidden
      // strategy indistinguishable from an unknown one, and the merge blocker
      // below is built on being able to tell those apart.
      expect(policy.strategies.mergeCommit, isFalse);
      expect(policy.strategies.rebase, isFalse);
    });

    test('a missing setting is null, never false', () {
      // The failure this avoids: a token that can read pull requests but not
      // repository settings gets a partial document, and reading the absence
      // as "not allowed" would disable a merge the repository permits.
      final policy = parseForgePolicy(
        '{"data":{"repository":{"pullRequest":{"reviewThreads":'
        '{"nodes":[]}}}},"errors":[{"message":"Resource not accessible"}]}',
      );
      expect(policy.strategies.mergeCommit, isNull);
      expect(policy.strategies.noneAllowed, isFalse);
      expect(policy.strategies.preferredLabel, isNull);
      expect(policy.unresolvedReviewThreads, 0);
    });

    test('absent threads are null, not zero', () {
      final policy = parseForgePolicy(
        '{"data":{"repository":{"squashMergeAllowed":true}}}',
      );
      expect(policy.unresolvedReviewThreads, isNull);
      expect(policy.strategies.squash, isTrue);
    });

    test('garbage and emptiness both degrade to knowing nothing', () {
      for (final body in ['', 'not json', '[]', '{"errors":[{}]}']) {
        final policy = parseForgePolicy(body);
        expect(policy, kUnknownForgePolicy, reason: body);
      }
    });
  });

  group('parsers', () {
    test('parseGhPullRequests reads number/title/state/author', () {
      final prs = parseGhPullRequests(
        '[{"number":7,"title":"Add x","state":"OPEN","author":{"login":"me"}}]',
      );
      expect(prs.single.number, 7);
      expect(prs.single.title, 'Add x');
      expect(prs.single.author, 'me');
    });

    test('parseGhIssues reads number/title/state', () {
      final issues = parseGhIssues(
        '[{"number":3,"title":"Bug","state":"OPEN"}]',
      );
      expect(issues.single.number, 3);
      expect(issues.single.title, 'Bug');
    });

    test('empty / non-list output yields nothing', () {
      expect(parseGhPullRequests(''), isEmpty);
      expect(parseGhIssues('{}'), isEmpty);
    });

    test('parseGhRepo reads metadata and default branch', () {
      final repo = parseGhRepo(
        '{"nameWithOwner":"me/app","description":"A thing",'
        '"url":"https://github.com/me/app","isPrivate":false,'
        '"stargazerCount":12,"defaultBranchRef":{"name":"main"}}',
      );
      expect(repo, isNotNull);
      expect(repo!.nameWithOwner, 'me/app');
      expect(repo.description, 'A thing');
      expect(repo.isPrivate, isFalse);
      expect(repo.stargazerCount, 12);
      expect(repo.defaultBranch, 'main');
    });

    test(
      'parseGhRepo tolerates missing description/branch and empty input',
      () {
        final repo = parseGhRepo(
          '{"nameWithOwner":"me/app","url":"u","isPrivate":true,'
          '"stargazerCount":0}',
        );
        expect(repo!.description, isNull);
        expect(repo.defaultBranch, isNull);
        expect(repo.isPrivate, isTrue);
        expect(parseGhRepo(''), isNull);
      },
    );
  });

  group('GitHubService', () {
    test('listPullRequests runs gh in the repo and parses JSON', () async {
      late CommandRequest captured;
      final runner = FakeCommandRunner(
        responder: (req) {
          captured = req;
          return const CommandResult(
            exitCode: 0,
            stdout: '[{"number":1,"title":"PR","state":"OPEN"}]',
            stderr: '',
          );
        },
      );
      final prs = await GitHubService(runner).listPullRequests(repo);
      expect(prs.single.number, 1);
      expect(captured.executable, 'gh');
      expect(captured.arguments, [
        'pr',
        'list',
        '--json',
        'number,title,state,author,url',
        '--limit',
        '50',
      ]);
      expect(captured.workingDirectory!.path, r'C:\app');
    });

    test('createPullRequest returns the URL gh prints', () async {
      final runner = FakeCommandRunner(
        responder: (_) => const CommandResult(
          exitCode: 0,
          stdout: 'https://github.com/o/r/pull/9\n',
          stderr: '',
        ),
      );
      final url = await GitHubService(
        runner,
      ).createPullRequest(repo, title: 'T', body: 'B');
      expect(url, 'https://github.com/o/r/pull/9');
    });

    test('a gh failure raises GitHubException', () async {
      final runner = FakeCommandRunner(
        responder: (_) => const CommandResult(
          exitCode: 1,
          stdout: '',
          stderr: 'gh: not authenticated',
        ),
      );
      expect(
        () => GitHubService(runner).listIssues(repo),
        throwsA(isA<GitHubException>()),
      );
    });

    test('pullRequestFor asks once for the PR and its checks', () async {
      late CommandRequest captured;
      final runner = FakeCommandRunner(
        responder: (req) {
          captured = req;
          return const CommandResult(
            exitCode: 0,
            stdout:
                '{"number":12,"title":"Work","state":"OPEN",'
                '"url":"https://github.com/o/r/pull/12","isDraft":false,'
                '"mergeable":"MERGEABLE","reviewDecision":"APPROVED",'
                '"headRefName":"work","statusCheckRollup":'
                '[{"__typename":"CheckRun","name":"build",'
                '"status":"COMPLETED","conclusion":"SUCCESS"}]}',
            stderr: '',
          );
        },
      );
      final pr = await GitHubService(
        runner,
      ).pullRequestFor(repo, branch: 'work');

      expect(captured.arguments.take(3), ['pr', 'view', 'work']);
      expect(captured.arguments.last, contains('statusCheckRollup'));
      expect(pr?.number, 12);
      expect(pr?.state, PullRequestState.open);
      expect(pr?.mergeable, isTrue);
      expect(pr?.reviewDecision, ReviewDecision.approved);
      expect(pr?.checks.state, ChecksState.passing);
      expect(pr?.isReadyToMerge, isTrue);
    });

    test('pullRequestFor asks GitHub for its own merge verdict', () async {
      // The field rides in the call that was already being made — it is the
      // same lazy computation `mergeable` triggers, so asking for both costs
      // one process and no extra work on GitHub's side.
      late CommandRequest captured;
      final runner = FakeCommandRunner(
        responder: (req) {
          captured = req;
          return const CommandResult(
            exitCode: 0,
            stdout:
                '{"number":12,"state":"OPEN","mergeStateStatus":"BEHIND"}',
            stderr: '',
          );
        },
      );
      final pr = await GitHubService(
        runner,
      ).pullRequestFor(repo, branch: 'work');

      expect(captured.arguments.join(','), contains('mergeStateStatus'));
      expect(pr?.mergeStateStatus, MergeStateStatus.behind);
    });

    test('forgePolicyFor asks graphql once, repo-relative', () async {
      late CommandRequest captured;
      final runner = FakeCommandRunner(
        responder: (req) {
          captured = req;
          return const CommandResult(
            exitCode: 0,
            stdout:
                '{"data":{"repository":{"squashMergeAllowed":true,'
                '"pullRequest":{"reviewThreads":{"nodes":'
                '[{"isResolved":false}]}}}}}',
            stderr: '',
          );
        },
      );
      final policy = await GitHubService(
        runner,
      ).forgePolicyFor(repo, number: 12);

      expect(captured.arguments.take(2), ['api', 'graphql']);
      // gh fills these from the working directory, which is how this stays a
      // repo-relative call like every other one in this service instead of
      // parsing the remote URL itself.
      expect(captured.arguments, contains('owner={owner}'));
      expect(captured.arguments, contains('name={repo}'));
      expect(captured.arguments, contains('number=12'));
      expect(captured.workingDirectory, repo);
      expect(policy.strategies.squash, isTrue);
      expect(policy.unresolvedReviewThreads, 1);
    });

    test('a graphql error still yields whatever the body carried', () async {
      // `gh api graphql` exits non-zero on a GraphQL error and prints the
      // document anyway. Throwing would discard a partial answer that is worth
      // more than none — and would turn a permissions quirk into a red row.
      final runner = FakeCommandRunner(
        responder: (_) => const CommandResult(
          exitCode: 1,
          stdout:
              '{"data":{"repository":{"squashMergeAllowed":true}},'
              '"errors":[{"message":"nope"}]}',
          stderr: 'gh: GraphQL error',
        ),
      );
      final policy = await GitHubService(
        runner,
      ).forgePolicyFor(repo, number: 12);
      expect(policy.strategies.squash, isTrue);
      expect(policy.unresolvedReviewThreads, isNull);
    });

    test('branchProtectionFor asks the base branch, repo-relative', () async {
      late CommandRequest captured;
      final runner = FakeCommandRunner(
        responder: (req) {
          captured = req;
          return const CommandResult(
            exitCode: 0,
            stdout:
                '{"url":"u","required_status_checks":{"strict":true,'
                '"contexts":["ci/build"]},'
                '"required_pull_request_reviews":'
                '{"required_approving_review_count":2,'
                '"require_code_owner_reviews":true},'
                '"required_signatures":{"enabled":true},'
                '"required_linear_history":{"enabled":false}}',
            stderr: '',
          );
        },
      );

      final protection = await GitHubService(
        runner,
      ).branchProtectionFor(repo, branch: 'main');

      expect(captured.arguments, [
        'api',
        'repos/{owner}/{repo}/branches/main/protection',
      ]);
      expect(captured.workingDirectory, repo);
      expect(protection.status, BranchProtectionRead.read);
      expect(protection.requiredApprovals, 2);
      expect(protection.requiresCodeOwnerReview, isTrue);
      expect(protection.requiredChecks, ['ci/build']);
      expect(protection.requiresSignatures, isTrue);
      // A `false` in the body is a fact; a missing key is not.
      expect(protection.requiresLinearHistory, isFalse);
      expect(protection.requiresConversationResolution, isFalse);
    });

    test('a 403 is the reader being refused, not the branch being open',
        () async {
      // The ordinary answer for anyone who is not an admin — `/protection` is
      // an admin-only endpoint — so it must not read as "no rules here".
      final runner = FakeCommandRunner(
        responder: (_) => const CommandResult(
          exitCode: 1,
          stdout:
              '{"message":"Must have admin rights to Repository.",'
              '"status":"403"}',
          stderr: 'gh: Must have admin rights to Repository. (HTTP 403)',
        ),
      );

      final protection = await GitHubService(
        runner,
      ).branchProtectionFor(repo, branch: 'main');

      expect(protection.status, BranchProtectionRead.forbidden);
      expect(protection.rules, isEmpty);
    });

    test('a 404 and a body that will not parse are both "could not tell"',
        () async {
      // 404 is what an unprotected branch answers — and also what a branch
      // guarded by a *ruleset* rather than by classic protection answers, so
      // it is never evidence that nothing is in the way.
      final missing = FakeCommandRunner(
        responder: (_) => const CommandResult(
          exitCode: 1,
          stdout: '{"message":"Branch not protected","status":"404"}',
          stderr: 'gh: Branch not protected (HTTP 404)',
        ),
      );
      expect(
        (await GitHubService(missing).branchProtectionFor(repo, branch: 'x'))
            .status,
        BranchProtectionRead.unknown,
      );

      final garbage = FakeCommandRunner(
        responder: (_) =>
            const CommandResult(exitCode: 0, stdout: 'not json', stderr: ''),
      );
      expect(
        (await GitHubService(garbage).branchProtectionFor(repo, branch: 'x'))
            .status,
        BranchProtectionRead.unknown,
      );
    });

    test('markPullRequestReady names the number rather than the branch',
        () async {
      late CommandRequest captured;
      final runner = FakeCommandRunner(
        responder: (req) {
          captured = req;
          return const CommandResult(exitCode: 0, stdout: '', stderr: '');
        },
      );
      await GitHubService(runner).markPullRequestReady(repo, number: 12);
      expect(captured.arguments, ['pr', 'ready', '12']);
    });

    test('a refused pr-ready throws with what gh said', () async {
      final runner = FakeCommandRunner(
        responder: (_) => const CommandResult(
          exitCode: 1,
          stdout: '',
          stderr: 'not a draft',
        ),
      );
      expect(
        () => GitHubService(runner).markPullRequestReady(repo, number: 12),
        throwsA(isA<GitHubException>()),
      );
    });

    test('a branch with no pull request is null, not an error', () async {
      final runner = FakeCommandRunner(
        responder: (_) => const CommandResult(
          exitCode: 1,
          stdout: '',
          stderr: 'no pull requests found for branch "work"',
        ),
      );
      expect(
        await GitHubService(runner).pullRequestFor(repo, branch: 'work'),
        isNull,
      );
    });

    test('gh being unusable still throws — that is not "there is no PR"', () {
      final runner = FakeCommandRunner(
        responder: (_) => const CommandResult(
          exitCode: 4,
          stdout: '',
          stderr: 'gh: You are not logged into any GitHub hosts',
        ),
      );
      expect(
        () => GitHubService(runner).pullRequestFor(repo, branch: 'work'),
        throwsA(isA<GitHubException>()),
      );
    });
  });

  group('parseCheckRollup', () {
    test('reads CheckRun status and conclusion', () {
      final checks = parseCheckRollup([
        {'status': 'COMPLETED', 'conclusion': 'SUCCESS'},
        {'status': 'COMPLETED', 'conclusion': 'FAILURE'},
        {'status': 'IN_PROGRESS'},
        {'status': 'COMPLETED', 'conclusion': 'SKIPPED'},
      ]);
      expect(checks.passed, 1);
      expect(checks.failed, 1);
      expect(checks.pending, 1);
      expect(checks.skipped, 1);
    });

    test('reads the older StatusContext shape too', () {
      final checks = parseCheckRollup([
        {'__typename': 'StatusContext', 'context': 'ci', 'state': 'SUCCESS'},
        {'__typename': 'StatusContext', 'context': 'lint', 'state': 'PENDING'},
        {'__typename': 'StatusContext', 'context': 'cov', 'state': 'ERROR'},
      ]);
      expect(checks.passed, 1);
      expect(checks.pending, 1);
      expect(checks.failed, 1);
    });

    test('a failure outranks a still-running neighbour', () {
      final checks = parseCheckRollup([
        {'status': 'COMPLETED', 'conclusion': 'FAILURE'},
        {'status': 'QUEUED'},
      ]);
      expect(checks.state, ChecksState.failing);
    });

    test('no checks is its own state, not passing', () {
      expect(parseCheckRollup(const []).state, ChecksState.none);
      expect(parseCheckRollup(null).state, ChecksState.none);
    });

    test('a completed run with no conclusion counts as running', () {
      final checks = parseCheckRollup([
        {'status': 'COMPLETED'},
      ]);
      expect(checks.state, ChecksState.pending);
    });
  });

  group('PullRequestSnapshot readiness', () {
    const base = PullRequestSnapshot(
      number: 1,
      state: PullRequestState.open,
      mergeable: true,
    );

    test('a draft is not ready even when everything is green', () {
      expect(base.isReadyToMerge, isTrue);
      expect(
        const PullRequestSnapshot(
          number: 1,
          state: PullRequestState.open,
          mergeable: true,
          isDraft: true,
        ).isReadyToMerge,
        isFalse,
      );
    });

    test('requested changes withhold readiness', () {
      expect(
        const PullRequestSnapshot(
          number: 1,
          state: PullRequestState.open,
          mergeable: true,
          reviewDecision: ReviewDecision.changesRequested,
        ).isReadyToMerge,
        isFalse,
      );
    });

    test('unknown mergeability is not readiness', () {
      expect(
        const PullRequestSnapshot(
          number: 1,
          state: PullRequestState.open,
        ).isReadyToMerge,
        isFalse,
      );
    });

    test('a failing check withholds readiness', () {
      expect(
        const PullRequestSnapshot(
          number: 1,
          state: PullRequestState.open,
          mergeable: true,
          checks: ChecksSummary(failed: 1),
        ).isReadyToMerge,
        isFalse,
      );
    });
  });
}
