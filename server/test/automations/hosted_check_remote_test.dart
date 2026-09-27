import 'package:agent_cli/process.dart';
import 'package:karmashala_automations/checks.dart';
import 'package:karmashala_host/src/automations/hosted_check_runner.dart';
import 'package:karmashala_host/src/domain/session_registry.dart';
import 'package:karmashala_host/src/pty/pty.dart';
import 'package:test/test.dart';

import '../agents/agent_work_support.dart' show ScriptedRunner;

/// A check on an SSH box runs as one command over the server's own
/// connection (slice 3a): its exit code is the verdict and its output the
/// tail; a command that could not run is a refusal, never a pass.
void main() {
  final check = ProjectCheck(
    id: 'c1',
    repositoryId: 'r1',
    name: 'the tests',
    command: const ['make', 'test'],
    createdAt: DateTime.utc(2026, 9, 27),
  );
  const directory = EnvironmentPath(environmentId: 'ssh:h1', path: '/srv/app');

  HostedCheckRunner runner(CommandRunner box) => HostedCheckRunner(
    registry: SessionRegistry(launcher: _NoPty()),
    newId: () => 'x',
    remote: (path) => path.environmentId.startsWith('ssh:') ? box : null,
  );

  test('runs in the checkout and keeps what it printed', () async {
    final box = ScriptedRunner(
      (_) => const CommandResult(
        exitCode: 2,
        stdout: 'ran 3\n',
        stderr: '1 failed',
      ),
      environmentId: 'ssh:h1',
    );
    final ran = await runner(
      box,
    ).execute(check, directory: directory, title: 'the tests');
    expect(ran.refusal, isNull);
    expect(ran.exitCode, 2);
    expect(ran.tail.join('\n'), contains('1 failed'));
    final request = box.requests.single;
    expect(request.executable, 'make');
    expect(request.arguments, ['test']);
    expect(request.workingDirectory, directory);
  });

  test('a box that cannot be reached is a refusal, not a verdict', () async {
    final box = ScriptedRunner(
      (_) => throw CommandException('Cannot reach 203.0.113.9:22'),
      environmentId: 'ssh:h1',
    );
    final ran = await runner(
      box,
    ).execute(check, directory: directory, title: 'the tests');
    expect(ran.exitCode, isNull);
    expect(ran.refusal, contains('Cannot reach'));
    expect(ran.refusal, contains('unknown, not proven'));
  });
}

/// Nothing is spawned here: a check on a box never opens a local pane.
class _NoPty implements PtyLauncher {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('a check on a box opened a local pane');
}
