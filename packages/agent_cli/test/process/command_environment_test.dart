import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:test/test.dart';

/// A request's environment reaches the process wherever it runs: handed to the
/// OS locally, and said as words of the command where this app's own
/// environment never arrives.
void main() {
  tearDownAll(sharedProcessSpawner.shutdown);

  const request = CommandRequest(
    executable: 'git',
    arguments: ['status'],
    environment: {'GIT_TERMINAL_PROMPT': '0'},
    removedEnvironment: {'GIT_DIR'},
  );

  test('the prefix removes first, then sets', () {
    expect(posixEnvironmentPrefix(request), [
      'env',
      '-u',
      'GIT_DIR',
      'GIT_TERMINAL_PROMPT=0',
    ]);
    expect(
      posixEnvironmentPrefix(const CommandRequest(executable: 'git')),
      isEmpty,
      reason: 'a request that names nothing is the command it always was',
    );
  });

  test('a WSL command carries it inside the distribution', () {
    final invocation = buildWslInvocation('Ubuntu', request);
    expect(invocation.arguments, [
      '-d',
      'Ubuntu',
      '--',
      'env',
      '-u',
      'GIT_DIR',
      'GIT_TERMINAL_PROMPT=0',
      'git',
      'status',
    ]);
    expect(
      invocation.hostRequest.environment,
      isEmpty,
      reason: "wsl.exe's own environment is not the distribution's",
    );
  });

  test('a local process gets what is set and loses what is removed', () async {
    final result = await const LocalCommandRunner().run(
      const CommandRequest(
        executable: '/usr/bin/env',
        environment: {'KARMASHALA_ENV_PROBE': 'set'},
        removedEnvironment: {'HOME'},
      ),
    );
    final lines = result.stdout.split('\n');
    expect(lines, contains('KARMASHALA_ENV_PROBE=set'));
    expect(lines.where((l) => l.startsWith('HOME=')), isEmpty);
    expect(
      lines.where((l) => l.startsWith('PATH=')),
      isNotEmpty,
      reason: 'everything not removed is still inherited',
    );
  }, skip: Platform.isWindows ? '/usr/bin/env is a POSIX witness' : null);
}
