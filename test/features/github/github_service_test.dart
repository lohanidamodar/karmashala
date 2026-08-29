import 'package:chitragupta/src/core/process/command_runner.dart';
import 'package:chitragupta/src/features/environments/domain/environment_path.dart';
import 'package:chitragupta/src/features/github/data/github_service.dart';
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
        'number,title,state,author',
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
  });
}
