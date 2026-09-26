import 'package:agent_cli/process.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/github/application/github_providers.dart';
import 'package:karmashala_git/github.dart';
import 'package:karmashala_store/database.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';

/// **The environment row reaches the refusal.** `GitHubService` can only name
/// where it looked if the app hands it the row it resolved; without that it
/// falls back to a database key, and `wsl:Ubuntu` is not what a person calls a
/// machine. Every gh-backed surface — the GitHub pane, the delivery strip's
/// Mark ready, Open a pull request, the strip's own polls — goes through this
/// one service.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.memory());
  tearDown(() => db.close());

  GitHubReviewService serviceFor(FakeCommandRunner runner) {
    final dao = ExecutionEnvironmentDao(db)
      ..upsert(windowsEnv())
      ..upsert(wslEnv());
    return GitHubReviewService(
      runnerFactory: FakeCommandRunnerFactory(fallback: runner),
      environmentDao: dao,
    );
  }

  test('a WSL checkout with no gh is refused for that distribution', () async {
    // What a missing gh inside WSL really looks like: wsl.exe starts, the
    // distribution's own shell cannot resolve the name, exit 127.
    final runner = FakeCommandRunner(
      environmentId: 'wsl:Ubuntu',
      responder: (_) => const CommandResult(
        exitCode: 127,
        stdout: '',
        stderr: 'bash: line 1: gh: command not found',
      ),
    );
    await expectLater(
      serviceFor(runner).pullRequests(
        const EnvironmentPath(
          environmentId: 'wsl:Ubuntu',
          path: '/home/me/app',
        ),
      ),
      throwsA(
        isA<GitHubException>()
            .having((e) => e.refusal, 'refusal', GitHubCliRefusal.notInstalled)
            .having(
              (e) => e.message,
              'message',
              allOf(
                contains('not installed in WSL · Ubuntu'),
                contains('https://cli.github.com'),
              ),
            ),
      ),
    );
  });

  test('a Windows checkout whose gh will not start says so, and where', () async {
    final runner = FakeCommandRunner(
      throwError: CommandException('Failed to run "gh" on windows'),
    );
    await expectLater(
      serviceFor(runner).issues(
        const EnvironmentPath(environmentId: 'windows', path: r'C:\src\app'),
      ),
      throwsA(
        isA<GitHubException>()
            .having((e) => e.refusal, 'refusal', GitHubCliRefusal.notInstalled)
            .having(
              (e) => e.message,
              'message',
              contains('not installed in Windows'),
            ),
      ),
    );
  });
}
