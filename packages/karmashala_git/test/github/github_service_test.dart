import 'package:agent_cli/process.dart';
import 'package:karmashala_git/github.dart';
import 'package:karmashala_git/github_testing.dart';
import 'package:test/test.dart';

import '../support/fake_command_runner.dart';

void main() {
  const repo = EnvironmentPath(environmentId: 'windows', path: r'C:\app');

  group('mergeStateStatus', () {
    // Every literal here is a value GitHub actually returned for a real pull
    // request; the shapes were taken from `gh pr view --json` against
    // `cli/cli` and `lohanidamodar/karmashala-app` on 2026-09-02.
    PullRequestSnapshot parse(String mergeStateStatus) =>
        parseGhPullRequestView(
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

  group('GitHubService over the API', () {
    late FakeGithubServer github;
    late FakeCommandRunner git;

    setUp(() async {
      github = await FakeGithubServer.start();
      git = FakeCommandRunner(
        responder: (request) => switch (request.arguments) {
          ['remote', 'get-url', 'origin'] => const CommandResult(
            exitCode: 0,
            stdout: 'git@github.com:o/r.git\n',
            stderr: '',
          ),
          ['rev-parse', '--abbrev-ref', 'HEAD'] => const CommandResult(
            exitCode: 0,
            stdout: 'work\n',
            stderr: '',
          ),
          _ => const CommandResult(exitCode: 1, stdout: '', stderr: 'no'),
        },
      );
    });

    tearDown(() => github.close());

    GitHubService service({Map<String, String>? tokens}) => GitHubService(
      git,
      client: fakeGithubClient(
        github,
        GithubCredentials(
          saved: GithubTokenMap(tokens ?? {'github.com': 'tok'}),
        ),
      ),
    );

    test('reads the repository off origin and asks for it', () async {
      github.on(
        'GET',
        '/repos/o/r',
        (_) => const FakeGithubReply(
          200,
          body: {
            'full_name': 'o/r',
            'html_url': 'https://github.com/o/r',
            'private': true,
            'stargazers_count': 3,
            'description': 'd',
            'default_branch': 'main',
          },
        ),
      );
      final repository = await service().getRepository(repo);
      expect(repository?.nameWithOwner, 'o/r');
      expect(repository?.isPrivate, isTrue);
      expect(repository?.defaultBranch, 'main');
      expect(git.requests.first.workingDirectory, repo);
    });

    test(
      'lists open pull requests and issues, leaving PRs out of issues',
      () async {
        github
          ..on(
            'GET',
            '/repos/o/r/pulls',
            (_) => const FakeGithubReply(
              200,
              body: [
                {
                  'number': 1,
                  'title': 'PR',
                  'state': 'open',
                  'user': {'login': 'me'},
                  'html_url': 'https://github.com/o/r/pull/1',
                },
              ],
            ),
          )
          ..on(
            'GET',
            '/repos/o/r/issues',
            (_) => const FakeGithubReply(
              200,
              body: [
                {'number': 2, 'title': 'Bug', 'state': 'open'},
                {
                  'number': 1,
                  'title': 'PR',
                  'state': 'open',
                  'pull_request': {},
                },
              ],
            ),
          );
        final gh = service();
        final prs = await gh.listPullRequests(repo);
        expect(prs.single.number, 1);
        expect(prs.single.state, 'OPEN');
        expect(prs.single.author, 'me');
        expect(
          github.requests.first.uri.queryParameters,
          containsPair('state', 'open'),
        );
        final issues = await gh.listIssues(repo);
        expect(issues.map((i) => i.number), [2]);
      },
    );

    test(
      'pullRequestFor reads the branch\'s pull request and its checks',
      () async {
        github.onGraphql({
          'pullRequests(headRefName': (request) {
            final variables = (request.json as Map)['variables'] as Map;
            expect(variables, {'owner': 'o', 'name': 'r', 'branch': 'work'});
            return const FakeGithubReply(
              200,
              body: {
                'data': {
                  'repository': {
                    'pullRequests': {
                      'nodes': [
                        {
                          'number': 12,
                          'title': 'Work',
                          'state': 'OPEN',
                          'url': 'https://github.com/o/r/pull/12',
                          'isDraft': false,
                          'mergeable': 'MERGEABLE',
                          'mergeStateStatus': 'BEHIND',
                          'reviewDecision': 'APPROVED',
                          'headRefName': 'work',
                          'baseRefName': 'main',
                          'headRepositoryOwner': {'login': 'o'},
                          'commits': {
                            'nodes': [
                              {
                                'commit': {
                                  'statusCheckRollup': {
                                    'contexts': {
                                      'nodes': [
                                        {
                                          '__typename': 'CheckRun',
                                          'status': 'COMPLETED',
                                          'conclusion': 'SUCCESS',
                                        },
                                      ],
                                    },
                                  },
                                },
                              },
                            ],
                          },
                        },
                      ],
                    },
                  },
                },
              },
            );
          },
        });
        final pr = await service().pullRequestFor(repo, branch: 'work');
        expect(pr?.number, 12);
        expect(pr?.state, PullRequestState.open);
        expect(pr?.mergeable, isTrue);
        expect(pr?.mergeStateStatus, MergeStateStatus.behind);
        expect(pr?.reviewDecision, ReviewDecision.approved);
        expect(pr?.checks.state, ChecksState.passing);
        expect(pr?.baseRefName, 'main');
      },
    );

    test('a branch with no pull request is null, not an error', () async {
      github.onGraphql({
        'pullRequests(headRefName': (_) => const FakeGithubReply(
          200,
          body: {
            'data': {
              'repository': {
                'pullRequests': {'nodes': []},
              },
            },
          },
        ),
      });
      expect(await service().pullRequestFor(repo, branch: 'work'), isNull);
    });

    test('no access is a refusal, not "there is no PR"', () async {
      await expectLater(
        service(tokens: {}).pullRequestFor(repo, branch: 'work'),
        throwsA(
          isA<GitHubException>()
              .having((e) => e.refusal, 'refusal', GitHubRefusal.noAccess)
              .having((e) => e.message, 'message', contains('gh auth login')),
        ),
      );
      expect(github.requests, isEmpty);
    });

    test('a checkout with no GitHub origin is refused in words', () async {
      git.responder = (_) =>
          const CommandResult(exitCode: 2, stdout: '', stderr: 'no origin');
      await expectLater(
        service().listIssues(repo),
        throwsA(
          isA<GitHubException>().having(
            (e) => e.refusal,
            'refusal',
            GitHubRefusal.noRemote,
          ),
        ),
      );
    });

    test(
      'forgePolicyFor asks GraphQL with the repository and number',
      () async {
        github.onGraphql({
          'reviewThreads': (request) {
            expect(((request.json as Map)['variables'] as Map)['number'], 12);
            return const FakeGithubReply(
              200,
              body: {
                'data': {
                  'repository': {
                    'squashMergeAllowed': true,
                    'pullRequest': {
                      'reviewThreads': {
                        'nodes': [
                          {'isResolved': false},
                        ],
                      },
                    },
                  },
                },
              },
            );
          },
        });
        final policy = await service().forgePolicyFor(repo, number: 12);
        expect(policy.strategies.squash, isTrue);
        expect(policy.unresolvedReviewThreads, 1);
      },
    );

    test('branch protection: rules read, 403 forbidden, 404 unknown', () async {
      github
        ..on(
          'GET',
          '/repos/o/r/branches/main/protection',
          (_) => const FakeGithubReply(
            200,
            body: {
              'url': 'u',
              'required_status_checks': {
                'contexts': ['ci/build'],
              },
              'required_pull_request_reviews': {
                'required_approving_review_count': 2,
              },
            },
          ),
        )
        ..on(
          'GET',
          '/repos/o/r/branches/locked/protection',
          (_) => const FakeGithubReply(
            403,
            body: {'message': 'Must have admin rights to Repository.'},
          ),
        );
      final gh = service();
      final main = await gh.branchProtectionFor(repo, branch: 'main');
      expect(main.status, BranchProtectionRead.read);
      expect(main.requiredApprovals, 2);
      expect(main.requiredChecks, ['ci/build']);
      expect(
        (await gh.branchProtectionFor(repo, branch: 'locked')).status,
        BranchProtectionRead.forbidden,
      );
      expect(
        (await gh.branchProtectionFor(repo, branch: 'open')).status,
        BranchProtectionRead.unknown,
      );
    });

    test('lists workflow runs on a branch', () async {
      github.on(
        'GET',
        '/repos/o/r/actions/runs',
        (_) => const FakeGithubReply(
          200,
          body: {
            'workflow_runs': [
              {
                'id': 77,
                'name': 'CI',
                'display_title': 'Fix',
                'status': 'completed',
                'conclusion': 'failure',
                'head_branch': 'work',
                'event': 'push',
                'html_url': 'https://github.com/o/r/actions/runs/77',
                'created_at': '2026-10-08T10:00:00Z',
                'run_attempt': 1,
              },
            ],
          },
        ),
      );
      final runs = await service().listWorkflowRuns(
        repo,
        branch: 'work',
        limit: 5,
      );
      expect(runs.single.id, 77);
      expect(runs.single.failed, isTrue);
      expect(runs.single.workflowName, 'CI');
      expect(github.requests.single.uri.queryParameters, {
        'branch': 'work',
        'per_page': '5',
      });
    });

    test('a failed run\'s log is its failed steps, fetched without the token '
        'where GitHub redirects it', () async {
      final blobs = await FakeGithubServer.start();
      addTearDown(blobs.close);
      blobs.on(
        'GET',
        '/log',
        (_) => const FakeGithubReply(
          200,
          body:
              '2026-10-08T10:00:01.1234567Z setting up\n'
              '2026-10-08T10:00:05.0000000Z ##[error]test failed\n'
              '2026-10-08T10:00:09.0000000Z cleaning up\n',
        ),
      );
      github
        ..on(
          'GET',
          '/repos/o/r/actions/runs/77/jobs',
          (_) => const FakeGithubReply(
            200,
            body: {
              'jobs': [
                {
                  'id': 5,
                  'name': 'build',
                  'conclusion': 'failure',
                  'steps': [
                    {
                      'name': 'Set up',
                      'conclusion': 'success',
                      'started_at': '2026-10-08T10:00:00Z',
                      'completed_at': '2026-10-08T10:00:02Z',
                    },
                    {
                      'name': 'Test',
                      'conclusion': 'failure',
                      'started_at': '2026-10-08T10:00:03Z',
                      'completed_at': '2026-10-08T10:00:06Z',
                    },
                  ],
                },
                {'id': 6, 'name': 'lint', 'conclusion': 'success'},
              ],
            },
          ),
        )
        ..on(
          'GET',
          '/repos/o/r/actions/jobs/5/logs',
          (_) => FakeGithubReply(
            302,
            headers: {'location': '${blobs.base.resolve('log')}'},
          ),
        );
      final log = await service().failedRunLog(repo, runId: 77);
      expect(log.tail, 'build | Test | ##[error]test failed');
      expect(log.errors, hasLength(1));
      expect(blobs.requests.single.authorization, isNull);
      expect(
        github.requests.map((r) => r.path),
        isNot(contains('/repos/o/r/actions/jobs/6/logs')),
      );
    });

    test('markPullRequestReady asks for the node and marks it ready', () async {
      github
        ..on(
          'GET',
          '/repos/o/r/pulls/12',
          (_) => const FakeGithubReply(200, body: {'node_id': 'PR_x'}),
        )
        ..onGraphql({
          'markPullRequestReadyForReview': (request) {
            expect((request.json as Map)['variables'], {'id': 'PR_x'});
            return const FakeGithubReply(
              200,
              body: {
                'data': {
                  'markPullRequestReadyForReview': {
                    'pullRequest': {'isDraft': false},
                  },
                },
              },
            );
          },
        });
      await service().markPullRequestReady(repo, number: 12);
      expect(github.requests.last.path, '/graphql');
    });

    test(
      'createPullRequest opens one from the branch onto the default',
      () async {
        github
          ..on(
            'GET',
            '/repos/o/r',
            (_) => const FakeGithubReply(
              200,
              body: {'full_name': 'o/r', 'default_branch': 'main'},
            ),
          )
          ..on('POST', '/repos/o/r/pulls', (request) {
            expect(request.json, {
              'title': 'T',
              'body': 'B',
              'head': 'work',
              'base': 'main',
            });
            return const FakeGithubReply(
              201,
              body: {'html_url': 'https://github.com/o/r/pull/9'},
            );
          });
        final url = await service().createPullRequest(
          repo,
          title: 'T',
          body: 'B',
        );
        expect(url, 'https://github.com/o/r/pull/9');
      },
    );

    test('GitHub refusing is a GitHubException with its message', () async {
      github.on(
        'GET',
        '/repos/o/r',
        (_) => const FakeGithubReply(404, body: {'message': 'Not Found'}),
      );
      await expectLater(
        service().getRepository(repo),
        throwsA(
          isA<GitHubException>()
              .having((e) => e.status, 'status', 404)
              .having((e) => e.message, 'message', contains('Not Found')),
        ),
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
