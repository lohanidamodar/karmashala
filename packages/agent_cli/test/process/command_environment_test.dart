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

  test('a WSL command removes inside the distribution and sets through '
      'WSLENV', () {
    final invocation = buildWslInvocation('Ubuntu', request);
    expect(invocation.arguments, [
      '-d',
      'Ubuntu',
      '--',
      'env',
      '-u',
      'GIT_DIR',
      'git',
      'status',
    ]);
    expect(invocation.hostRequest.environment, {
      'GIT_TERMINAL_PROMPT': '0',
      'WSLENV': 'GIT_TERMINAL_PROMPT/u',
    });
  });

  group('a WSL variable', () {
    const hostile =
        r'a b;$HOME "q" '
        "'"
        r'$(id)`x`';

    for (final exec in [false, true]) {
      test('reaches wsl.exe byte for byte and never its command line '
          '(exec: $exec)', () {
        final host = buildWslInvocation(
          'Ubuntu',
          const CommandRequest(
            executable: 'agent',
            environment: {'API_KEY': hostile},
          ),
          exec: exec,
        ).hostRequest;
        expect(host.environment['API_KEY'], hostile);
        expect(host.environment['WSLENV'], 'API_KEY/u');
        expect(host.arguments.join(' '), isNot(contains('API_KEY')));
        expect(host.arguments, [
          '-d',
          'Ubuntu',
          exec ? '--exec' : '--',
          'agent',
        ]);
      });
    }

    test('keeps the inherited WSLENV, replacing an entry of the same name', () {
      final host = buildWslInvocation(
        'Ubuntu',
        const CommandRequest(
          executable: 'agent',
          environment: {'API_KEY': 'k', 'MODE': 'x'},
        ),
        inheritedWslEnv: 'USERPROFILE/p:api_key/p:',
      ).hostRequest;
      expect(host.environment['WSLENV'], 'USERPROFILE/p:API_KEY/u:MODE/u');
    });

    test('that is both removed and set is set', () {
      final host = buildWslInvocation(
        'Ubuntu',
        const CommandRequest(
          executable: 'agent',
          environment: {'MODE': 'x'},
          removedEnvironment: {'MODE'},
        ),
      ).hostRequest;
      expect(host.arguments, ['-d', 'Ubuntu', '--', 'agent']);
      expect(host.environment['MODE'], 'x');
    });

    test('named outside POSIX is refused, never sent', () {
      for (final name in ['A B', 'A=B', 'A:B', 'A/u', '1A', '']) {
        expect(
          () => buildWslInvocation(
            'Ubuntu',
            CommandRequest(executable: 'agent', environment: {name: 'v'}),
          ),
          throwsA(isA<CommandException>()),
          reason: name,
        );
      }
      expect(
        () => buildWslInvocation(
          'Ubuntu',
          const CommandRequest(
            executable: 'agent',
            removedEnvironment: {'A;B'},
          ),
        ),
        throwsA(isA<CommandException>()),
      );
    });
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
