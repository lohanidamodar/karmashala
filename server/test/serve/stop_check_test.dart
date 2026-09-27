@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:test/test.dart';

import '../server/server_test_support.dart';

/// `stop` against hosts of another protocol. Found live: a protocol-17 host
/// could not be stopped without `--force`, because `stop` asked over hello.
/// The host here answers only the frozen stop check, as any version will.
void main() {
  late Directory dir;
  late HostPaths paths;
  late ServerSocket host;
  late Process served;

  /// What the host answers the stop check with; null answers as a host from
  /// before it did — a `badRequest` for a frame type it does not know.
  StopCheckAnswerMessage? Function(int requestId) answerWith = (_) => null;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('ks-stop-check');
    paths = HostPaths(dir);
    served = await Process.start('sleep', ['60']);
    File(paths.lockPath).writeAsStringSync('${served.pid}');
    host = await ServerSocket.bind(
      InternetAddress(paths.socketPath, type: InternetAddressType.unix),
      0,
    );
    host.listen((socket) {
      final parser = FrameParser();
      socket.listen((chunk) {
        final List<Frame> frames;
        try {
          frames = parser.add(chunk);
        } on FrameFormatException catch (e) {
          socket.add(
            ErrorMessage(0, ProtocolErrorCode.badRequest, e.message)
                .toFrame()
                .encode(),
          );
          socket.destroy();
          return;
        }
        for (final frame in frames) {
          final check = decodeMessage(frame) as StopCheckMessage;
          final answer = answerWith(check.requestId);
          socket.add(
            (answer ??
                    ErrorMessage(
                      0,
                      ProtocolErrorCode.badRequest,
                      'unknown message type 0xf0',
                    ))
                .toFrame()
                .encode(),
          );
          socket.destroy();
        }
      });
    });
  });

  tearDown(() async {
    served.kill(ProcessSignal.sigkill);
    await host.close();
    dir.deleteSync(recursive: true);
  });

  Future<(int, String, String)> stop(List<String> args) async {
    final out = CapturingSink();
    final err = CapturingSink();
    final code = await runStop(
      args,
      out: out,
      err: err,
      paths: paths,
      answerWithin: const Duration(seconds: 2),
      grace: const Duration(seconds: 2),
    );
    return (code, out.text.toString(), err.text.toString());
  }

  StopCheckAnswerMessage Function(int) answering(int running) =>
      (requestId) => StopCheckAnswerMessage(
        requestId: requestId,
        protocolVersion: kProtocolVersion + 1,
        pid: served.pid,
        runningSessions: running,
      );

  test('a host of another protocol holding nothing is stopped', () async {
    answerWith = answering(0);
    final (code, out, err) = await stop(const []);
    expect(code, 0, reason: err);
    expect(out, contains('stopped pid ${served.pid}'));
    expect(await served.exitCode.timeout(const Duration(seconds: 5)), isNot(0));
  });

  test('one holding running sessions is refused, and left running', () async {
    answerWith = answering(2);
    final (code, _, err) = await stop(const []);
    expect(code, 3);
    expect(err, contains('2 session(s) are still running'));
    expect(processIsAlive(served.pid), isTrue);
  });

  test('--force stops it anyway', () async {
    answerWith = answering(2);
    final (code, out, err) = await stop(const ['--force']);
    expect(code, 0, reason: err);
    expect(out, contains('stopped pid ${served.pid}'));
  });

  test('a host that predates the check is unknown: refused without --force, '
      'stopped by its lock with it', () async {
    answerWith = (_) => null;
    final (refused, _, err) = await stop(const []);
    expect(refused, 3);
    expect(err, contains('would not answer'));
    expect(err, contains('unknown message type'));
    expect(processIsAlive(served.pid), isTrue);

    final (forced, out, _) = await stop(const ['--force']);
    expect(forced, 0);
    expect(out, contains('stopped pid ${served.pid}'));
  });
}
