import 'dart:async';

import 'package:agent_cli/process.dart';
import 'package:karmashala_host/src/acp/acp_transport.dart';
import 'package:test/test.dart';

import '../support/fake_command_runner.dart';

/// An agent's process can be started again with arguments added after its
/// own — what a bridge needs when its protocol picks the conversation on argv.
void main() {
  const request = CommandRequest(
    executable: 'claude',
    arguments: ['-p', '--input-format', 'stream-json'],
    workingDirectory: EnvironmentPath(environmentId: 'windows', path: r'C:\w'),
    environment: {'A': '1'},
    removedEnvironment: {'B'},
  );

  test(
    'a relaunch runs the same command with the extra arguments last',
    () async {
      final runner = FakeCommandRunner();
      final first = await startAcpProcess(runner.start, request);
      final again = await first.relaunch!(['--resume', 'abc']);
      expect(runner.startRequests, hasLength(2));
      final second = runner.startRequests.last;
      expect(second.executable, 'claude');
      expect(second.arguments, [
        '-p',
        '--input-format',
        'stream-json',
        '--resume',
        'abc',
      ]);
      expect(second.workingDirectory?.path, r'C:\w');
      expect(second.environment, {'A': '1'});
      expect(second.removedEnvironment, {'B'});
      // A relaunched process can itself be relaunched, from the original argv.
      await again.relaunch!(['--version']);
      expect(runner.startRequests.last.arguments, [
        '-p',
        '--input-format',
        'stream-json',
        '--version',
      ]);
    },
  );

  test('a transport over streams has no relaunch unless given one', () {
    expect(
      AcpTransport.streams(
        output: const Stream.empty(),
        input: _NullSink(),
        exitCode: Future.value(0),
      ).relaunch,
      isNull,
    );
  });
}

final class _NullSink implements StreamSink<List<int>> {
  @override
  void add(List<int> event) {}
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<List<int>> stream) async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> get done async {}
}
