@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:test/test.dart';

/// `stop` against a host that takes the connection and never welcomes it — the
/// state a pty close left one in on 2026-09-24. The lock's pid is the only way
/// to reach it, and until then `connect` threw before `stop` could look there.
void main() {
  late Directory dir;
  late HostPaths paths;
  late ServerSocket silent;
  late Process wedged;
  final out = StringBuffer();
  final err = StringBuffer();

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('ks-stop');
    paths = HostPaths(dir);
    // Accepts, reads nothing, answers nothing.
    silent = await ServerSocket.bind(
      InternetAddress(paths.socketPath, type: InternetAddressType.unix),
      0,
    );
    silent.listen((_) {});
    wedged = await Process.start('sleep', ['60']);
    File(paths.lockPath).writeAsStringSync('${wedged.pid}');
    out.clear();
    err.clear();
  });

  tearDown(() async {
    wedged.kill(ProcessSignal.sigkill);
    await silent.close();
    dir.deleteSync(recursive: true);
  });

  Future<int> stop(List<String> args) {
    final outSink = _BufferSink(out);
    final errSink = _BufferSink(err);
    return runStop(
      args,
      out: outSink,
      err: errSink,
      paths: paths,
      answerWithin: const Duration(milliseconds: 200),
      grace: const Duration(seconds: 2),
    );
  }

  test(
    'without --force it refuses, because what it holds is unknown',
    () async {
      expect(await stop(const []), 3);
      expect(err.toString(), contains('would not answer'));
      expect(err.toString(), contains('--force'));
      expect(Process.killPid(wedged.pid, ProcessSignal.sigcont), isTrue);
    },
  );

  test('--force stops it by the pid in its lock', () async {
    expect(await stop(const ['--force']), 0, reason: '$err');
    expect(out.toString(), contains('stopped pid ${wedged.pid}'));
    expect(await wedged.exitCode.timeout(const Duration(seconds: 5)), isNot(0));
  });
}

class _BufferSink implements IOSink {
  _BufferSink(this._buffer);
  final StringBuffer _buffer;

  @override
  void writeln([Object? object = '']) => _buffer.writeln(object);

  @override
  void write(Object? object) => _buffer.write(object);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
