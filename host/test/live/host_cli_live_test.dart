@Tags(['live'])
library;

import 'dart:io';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:test/test.dart';

import 'local_host_harness.dart';

/// **The host, operated by hand.** `attach` is for the app; somebody sitting on
/// the machine over SSH had no way to see what was running or end it — which is
/// how six orphaned sessions stayed alive on a droplet for two days.
void main() {
  late LocalHost host;
  late _Captured out;
  late _Captured err;

  setUp(() async {
    host = await LocalHost.start(temporaryHome('karmashala-host-cli'));
    out = _Captured();
    err = _Captured();
  });

  tearDown(() async => host.kill());

  Future<String> openOne(String id) async {
    final client = await LocalHostClient.connect(host.socketPath, 'test');
    client.send(
      OpenMessage(
        requestId: 10,
        sessionId: id,
        argv: Platform.isWindows
            ? ['cmd.exe']
            : ['/bin/sh', '-c', 'sleep 120'],
        environment: const {},
        columns: 80,
        rows: 24,
      ),
    );
    await client.expect<AttachedMessage>();
    await client.close();
    return id;
  }

  test('list says nothing is running before anything is', () async {
    final code = await runList(out: out.sink, err: err.sink, paths: host.paths);

    expect(code, 0);
    expect(out.text, contains('no sessions'));
  });

  test('list names a session, its pid and its command', () async {
    await openOne('cli-one');

    final code = await runList(out: out.sink, err: err.sink, paths: host.paths);

    expect(code, 0);
    expect(out.text, contains('cli-one'));
    expect(out.text, contains('running'));
    expect(out.text, contains('SESSION'));
  });

  test('end takes one session down and names its ending', () async {
    await openOne('cli-two');

    final ended = await runEnd(
      ['cli-two'],
      out: out.sink,
      err: err.sink,
      paths: host.paths,
    );
    expect(ended, 0);
    expect(out.text, contains('ended cli-two'));

    final after = _Captured();
    await runList(out: after.sink, err: err.sink, paths: host.paths);
    // The record stays — the host keeps what happened — but it is not running.
    expect(after.text, isNot(contains('running')));
  });

  test('end refuses a session that was never here, in words', () async {
    final code = await runEnd(
      ['nobody'],
      out: out.sink,
      err: err.sink,
      paths: host.paths,
    );

    expect(code, 6);
    expect(err.text, contains('karmashala_host end'));
  });

  test('stop refuses while a session is running, and says how many', () async {
    await openOne('cli-three');

    final code = await runStop(
      const [],
      out: out.sink,
      err: err.sink,
      paths: host.paths,
    );

    expect(code, 3);
    expect(err.text, contains('1 session(s)'));
    expect(err.text, contains('--force'));
    // Refused means refused: the host is still there.
    expect(File(host.paths.socketPath).existsSync(), isTrue);
  });

  test('stop --force takes the host down with what it holds', () async {
    await openOne('cli-four');

    final code = await runStop(
      const ['--force'],
      out: out.sink,
      err: err.sink,
      paths: host.paths,
    );

    expect(code, 0);
    expect(out.text, contains('stopped pid'));
    await host.process.exitCode.timeout(const Duration(seconds: 20));
  });

  test('an empty host stops without being forced', () async {
    final code = await runStop(
      const [],
      out: out.sink,
      err: err.sink,
      paths: host.paths,
    );

    expect(code, 0);
    expect(out.text, contains('stopped pid'));
  });

  test('every command says where it looked when nothing is there', () async {
    await host.kill();
    // The socket node outlives a killed daemon, so this is the "present but
    // nobody answering" case rather than a missing file.
    final list = await runList(out: out.sink, err: err.sink, paths: host.paths);

    expect(list, 5);
    expect(err.text, contains(host.paths.socketPath));
  });
}

class _Captured {
  final _buffer = StringBuffer();
  late final IOSink sink = _CapturingSink(_buffer);
  String get text => _buffer.toString();
}

class _CapturingSink implements IOSink {
  _CapturingSink(this._buffer);
  final StringBuffer _buffer;

  @override
  void writeln([Object? object = '']) => _buffer.writeln(object);

  @override
  void write(Object? object) => _buffer.write(object);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
