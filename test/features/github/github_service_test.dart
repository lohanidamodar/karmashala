import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';
import 'package:karmashala/src/features/github/data/github_service.dart';
import 'package:karmashala/src/features/github/domain/pull_request_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';

void main() {
  const repo = EnvironmentPath(environmentId: 'windows', path: r'C:\app');

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
