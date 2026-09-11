import 'dart:io';

import 'package:agent_cli/src/process/command_runner.dart';
import 'package:agent_cli/src/process/local_command_runner.dart';
import 'package:agent_cli/src/process/process_spawner.dart';
import 'package:test/test.dart';

/// A probe that never returns used to hang discovery forever; a request may now
/// carry a bound, and the bound kills the child and names itself.
void main() {
  test('a child that outlives its bound is killed and the caller told', () async {
    const runner = LocalCommandRunner(spawner: InlineProcessSpawner());
    final started = DateTime.now();

    await expectLater(
      runner.run(_sleep(timeout: const Duration(milliseconds: 300))),
      throwsA(
        isA<CommandException>().having(
          (e) => e.message,
          'message',
          allOf(contains('did not finish within'), contains('was killed')),
        ),
      ),
    );
    expect(
      DateTime.now().difference(started),
      lessThan(const Duration(seconds: 4)),
      reason: 'the wait ended on the bound, not on the child',
    );
  });

  test('the same words arrive from the worker isolate', () async {
    final spawner = IsolateProcessSpawner();
    addTearDown(spawner.shutdown);
    final runner = LocalCommandRunner(spawner: spawner);

    await expectLater(
      runner.run(_sleep(timeout: const Duration(milliseconds: 300))),
      throwsA(
        isA<CommandException>().having(
          (e) => e.message,
          'message',
          contains('did not finish within'),
        ),
      ),
    );
  });

  test('a child that finishes inside its bound is answered as before', () async {
    const runner = LocalCommandRunner(spawner: InlineProcessSpawner());

    final result = await runner.run(_echo('bounded', timeout: const Duration(seconds: 30)));

    expect(result.exitCode, 0);
    expect(result.stdout.trim(), 'bounded');
  });

  test('a request with no bound is unchanged: it carries none', () {
    expect(const CommandRequest(executable: 'x').timeout, isNull);
  });
}

String get _shell => Platform.isWindows ? 'cmd.exe' : 'sh';

CommandRequest _sleep({required Duration timeout}) => CommandRequest(
  executable: _shell,
  arguments: Platform.isWindows
      ? ['/c', 'ping', '-n', '6', '127.0.0.1']
      : ['-c', 'sleep 5'],
  timeout: timeout,
);

CommandRequest _echo(String token, {required Duration timeout}) => CommandRequest(
  executable: _shell,
  arguments: Platform.isWindows ? ['/c', 'echo $token'] : ['-c', 'echo $token'],
  timeout: timeout,
);
