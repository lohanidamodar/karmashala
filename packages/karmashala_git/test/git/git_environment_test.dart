import 'dart:async';

import 'package:agent_cli/process.dart';
import 'package:karmashala_git/git.dart';
import 'package:test/test.dart';

import '../support/fake_command_runner.dart';

/// Every git this app runs never prompts, never takes an optional lock, and
/// never inherits a repository location from wherever this app was started.
void main() {
  const repo = EnvironmentPath(environmentId: 'windows', path: r'C:\src\app');

  void expectScrubbed(CommandRequest request) {
    expect(request.environment, kGitChildEnvironment);
    expect(request.removedEnvironment, kGitRemovedEnvironment);
  }

  test('a run-to-completion git', () async {
    final runner = FakeCommandRunner();
    await GitService(runner).currentBranch(repo);
    expectScrubbed(runner.requests.single);
  });

  test('a streamed git', () async {
    final runner = FakeCommandRunner();
    final cancel = Completer<void>();
    final streaming = GitService(
      runner,
    ).streamGit(repo, const ['fetch'], cancel: cancel.future);
    await Future<void>.delayed(Duration.zero);
    expectScrubbed(runner.startRequests.single);
    cancel.complete();
    await expectLater(streaming, throwsA(isA<GitCancelled>()));
  });

  test('the environment is the one the backlog names', () {
    expect(kGitChildEnvironment, {
      'GIT_TERMINAL_PROMPT': '0',
      'GCM_INTERACTIVE': 'never',
      'GIT_OPTIONAL_LOCKS': '0',
    });
    expect(kGitRemovedEnvironment, {
      'GIT_DIR',
      'GIT_WORK_TREE',
      'GIT_COMMON_DIR',
      'GIT_INDEX_FILE',
    });
  });
}
