import 'package:agent_cli/process.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:test/test.dart';

import '../support/fake_command_runner.dart';

/// Repositories under a folder only a runner reaches (WSL, an SSH box),
/// found with `find` there; and whether a folder is there at all — asked of
/// the machine, never guessed. Moved from the app (slice 3a) so the server
/// scans an SSH box with the same rules.
void main() {
  const root = EnvironmentPath(environmentId: 'ssh:h1', path: '/srv/work');

  test('each .git found is a checkout, skipped folders excluded', () async {
    final runner = FakeCommandRunner(
      environmentId: 'ssh:h1',
      responder: (_) => const CommandResult(
        exitCode: 0,
        stdout:
            '/srv/work/b/.git\n'
            '/srv/work/a/.git\n'
            '/srv/work/a/node_modules/x/.git\n'
            '/srv/work/a/.git\n',
        stderr: '',
      ),
    );
    final found = await PosixRepositoryDiscovery(
      runner,
      environmentName: 'box',
    ).discover(root, maxDepth: 3);

    expect(found.map((r) => r.path.path), ['/srv/work/a', '/srv/work/b']);
    expect(found.first.name, 'a');
    expect(found.first.path.environmentId, 'ssh:h1');
    final script = runner.requests.single.arguments.last;
    expect(script, contains("ROOT='/srv/work'"));
    expect(script, contains('-maxdepth 4'));
  });

  test('a root that is not there is refused in its own words', () async {
    final runner = FakeCommandRunner(
      responder: (_) => const CommandResult(
        exitCode: 2,
        stdout: '',
        stderr: 'Repository root does not exist: /srv/work',
      ),
    );
    expect(
      () => PosixRepositoryDiscovery(
        runner,
        environmentName: 'box',
      ).discover(root),
      throwsA(
        isA<RepositoryDiscoveryException>().having(
          (e) => e.message,
          'message',
          contains('does not exist'),
        ),
      ),
    );
  });

  test('presence is present, absent, or unknown when nobody answered', () async {
    Future<CheckoutPresence> presence(CommandResult Function() answer) =>
        PosixRepositoryDiscovery(
          FakeCommandRunner(responder: (_) => answer()),
          environmentName: 'box',
        ).presenceOf(root);

    expect(
      await presence(
        () => const CommandResult(exitCode: 0, stdout: 'yes\n', stderr: ''),
      ),
      CheckoutPresence.present,
    );
    expect(
      await presence(
        () => const CommandResult(exitCode: 0, stdout: 'no\n', stderr: ''),
      ),
      CheckoutPresence.absent,
    );
    expect(
      await presence(() => throw CommandException('Cannot reach the box')),
      CheckoutPresence.unknown,
    );
  });
}
