import 'dart:async';
import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/lifecycle_client.dart' show HostLifecycleWatch;
import 'package:karmashala_host/src/agents/forwarded_runs.dart';
import 'package:test/test.dart';

T roundTrip<T extends HostMessage>(HostMessage message) {
  final frames = FrameParser().add(message.toFrame().encode());
  return decodeMessage(frames.single) as T;
}

/// Protocol 18's forwarded commands: the three frames, and the whole path
/// over a real unix socket — the app offers, the server's run becomes a call
/// on the app's link, and the app's answer is the server's result.
void main() {
  test('the frames keep their numbers', () {
    expect(MessageType.runOffer.code, 0x38);
    expect(MessageType.runCall.code, 0x39);
    expect(MessageType.runResult.code, 0x3a);
    expect(kProtocolVersion, 18);
  });

  test('an offer round-trips', () {
    expect(
      roundTrip<RunOfferMessage>(const RunOfferMessage()),
      isA<RunOfferMessage>(),
    );
  });

  test('a call keeps its id, environment and command', () {
    final command = commandRequestToJson(
      const CommandRequest(
        executable: 'sh',
        arguments: ['-c', 'cat > "\$1"', 'sh', '/home/dev/.codex/auth.json'],
        stdinText: '{"tokens": {}}\n',
        timeout: Duration(seconds: 60),
        environment: {'LANG': 'C'},
      ),
    );
    final call = roundTrip<RunCallMessage>(
      RunCallMessage(callId: 12, environmentId: 'ssh:h1', command: command),
    );
    expect(call.callId, 12);
    expect(call.environmentId, 'ssh:h1');
    expect(call.command, command);
    final back = commandRequestFromJson(call.command);
    expect(back.stdinText, '{"tokens": {}}\n');
    expect(back.timeout, const Duration(seconds: 60));
    expect(back.environment, {'LANG': 'C'});
  });

  test('a result is how it ran, or why it could not', () {
    final ran = roundTrip<RunResultMessage>(
      const RunResultMessage.ran(4, exitCode: 2, stdout: 'out', stderr: 'err'),
    );
    expect(ran.callId, 4);
    expect(ran.exitCode, 2);
    expect(ran.stdout, 'out');
    expect(ran.stderr, 'err');
    expect(ran.error, isNull);

    final quiet = roundTrip<RunResultMessage>(
      const RunResultMessage.ran(5, exitCode: 0, stdout: '', stderr: ''),
    );
    expect(quiet.exitCode, 0);
    expect(quiet.stdout, '');
    expect(quiet.stderr, '');

    final failed = roundTrip<RunResultMessage>(
      const RunResultMessage.failed(6, 'no route to build-box'),
    );
    expect(failed.callId, 6);
    expect(failed.error, 'no route to build-box');
    expect(failed.exitCode, isNull);
    expect(failed.stdout, isNull);
  });

  test('a call without its command is a format error', () {
    final frame = Frame(
      MessageType.runCall,
      0,
      (WireWriter()..str('{"callId": 1, "environmentId": "ssh:h1"}')).take(),
    );
    expect(() => decodeMessage(frame), throwsA(isA<WireFormatException>()));
  });

  group('over a unix socket', () {
    late Directory dir;
    late HostServer server;
    late UnixSocketHostListener listener;
    late StreamSubscription<HostConnection> serving;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('kruns');
      server = HostServer(
        registry: SessionRegistry(launcher: FakePtyLauncher()),
        ptyLibrary: 'libc',
      );
      listener = await UnixSocketHostListener.bind('${dir.path}/h.sock');
      serving = server.listen(listener);
    });

    tearDown(() async {
      server.runs.close();
      await serving.cancel();
      await listener.close();
      dir.deleteSync(recursive: true);
    });

    Future<void> untilOffered() async {
      for (var i = 0; i < 500 && !server.runs.connected; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(server.runs.connected, isTrue, reason: 'the offer never arrived');
    }

    test('the app offers, is called, and its answer is the result', () async {
      final app = (await HostLifecycleWatch.connect(listener.path))!;
      addTearDown(app.close);
      final calls = StreamIterator(app.runCalls);
      app.offerRuns();
      await untilOffered();

      final running = server.runs.run(
        'ssh:h1',
        const CommandRequest(
          executable: 'uname',
          arguments: ['-a'],
          stdinText: 'nothing secret',
        ),
      );
      expect(
        await calls.moveNext().timeout(const Duration(seconds: 5)),
        isTrue,
      );
      final call = calls.current;
      expect(call.environmentId, 'ssh:h1');
      final asked = commandRequestFromJson(call.command);
      expect(asked.executable, 'uname');
      expect(asked.arguments, ['-a']);
      expect(asked.stdinText, 'nothing secret');

      app.answerRunCall(
        RunResultMessage.ran(
          call.callId,
          exitCode: 0,
          stdout: 'Linux build-box',
          stderr: '',
        ),
      );
      final result = await running.timeout(const Duration(seconds: 5));
      expect(result.exitCode, 0);
      expect(result.stdout, 'Linux build-box');

      // A command the app could not run fails at the server, in its words.
      final refused = server.runs.run(
        'ssh:h1',
        const CommandRequest(executable: 'true'),
      );
      expect(
        await calls.moveNext().timeout(const Duration(seconds: 5)),
        isTrue,
      );
      app.answerRunCall(
        RunResultMessage.failed(calls.current.callId, 'host key changed'),
      );
      await expectLater(
        refused.timeout(const Duration(seconds: 5)),
        throwsA(
          isA<CommandException>().having(
            (e) => e.message,
            'message',
            'host key changed',
          ),
        ),
      );
      await calls.cancel();
    });

    test('the app hanging up fails what it held', () async {
      final app = (await HostLifecycleWatch.connect(listener.path))!;
      app.offerRuns();
      await untilOffered();
      final calls = StreamIterator(app.runCalls);
      final running = server.runs.run(
        'ssh:h1',
        const CommandRequest(executable: 'sleep', arguments: ['9']),
      );
      expect(
        await calls.moveNext().timeout(const Duration(seconds: 5)),
        isTrue,
      );
      await app.close();
      await expectLater(
        running.timeout(const Duration(seconds: 5)),
        throwsA(isA<CommandException>()),
      );
      for (var i = 0; i < 500 && server.runs.connected; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(server.runs.connected, isFalse);
    });
  });
}
