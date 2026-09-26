/// `karmashala_host relay`: the relay a box runs for one desktop. Started
/// in-process on an ephemeral port, dialled over real loopback.
library;

import 'dart:convert';
import 'dart:io';

import 'package:karmashala_host/src/cli.dart';
import 'package:karmashala_host/src/relay/relay_command.dart';
import 'package:test/test.dart';

import '../server/server_test_support.dart' show kNowhereEnvironment;

/// An [IOSink] that keeps what it was given, for reading back what was said.
class _Sink implements IOSink {
  final StringBuffer text = StringBuffer();

  @override
  Encoding encoding = utf8;

  @override
  void write(Object? object) => text.write(object);

  @override
  void writeln([Object? object = '']) => text.writeln(object);

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      text.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => text.writeCharCode(charCode);

  @override
  void add(List<int> data) => text.write(utf8.decode(data));

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.forEach(add);

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> get done async {}
}

const _rendezvous = '0123456789abcdef0123456789abcdef';

void main() {
  late Directory home;
  late _Sink out;
  late _Sink err;
  StartedRelay? started;

  setUp(() {
    home = Directory.systemTemp.createTempSync('karmashala-relay-test');
    out = _Sink();
    err = _Sink();
  });

  tearDown(() async {
    await started?.stop();
    started = null;
    home.deleteSync(recursive: true);
  });

  List<String> args({int port = 0}) => [
    '--port=$port',
    '--address=127.0.0.1',
    '--token-file=${home.path}/relay.token',
    '--pid-file=${home.path}/relay.pid',
  ];

  Future<int> status(Uri url) async {
    final client = HttpClient();
    try {
      final response = await (await client.getUrl(url)).close();
      await response.drain<void>();
      return response.statusCode;
    } finally {
      client.close(force: true);
    }
  }

  test('mints an owner-only token, serves under it, and cleans up', () async {
    final result = await startRelay(args(), out: out, err: err);
    started = result.relay;
    expect(result.exitCode, 0, reason: err.text.toString());
    final relay = started!;

    final tokenFile = File('${home.path}/relay.token');
    final token = tokenFile.readAsStringSync().trim();
    expect(token, matches(RegExp(r'^[0-9a-f]{32}$')));
    if (!Platform.isWindows) {
      expect(tokenFile.statSync().mode & 0x3F, 0, reason: 'group/other bits');
    }
    expect(File('${home.path}/relay.pid').readAsStringSync().trim(), '$pid');

    final base = 'http://127.0.0.1:${relay.port}';
    expect(await status(Uri.parse('$base/k/$token/healthz')), 200);
    expect(await status(Uri.parse('$base/healthz')), 404);

    // A real pair of sockets under the prefix: this is the relay, not a stub.
    final url = 'ws://127.0.0.1:${relay.port}/k/$token/v1/$_rendezvous';
    final desktop = await WebSocket.connect(url);
    final phone = await WebSocket.connect(url);
    desktop.add([1, 2, 3]);
    expect(await phone.first, [1, 2, 3]);
    await desktop.close();

    // Said nothing a log could leak.
    expect(out.text.toString(), isNot(contains(token)));
    expect(err.text.toString(), isNot(contains(token)));

    await relay.stop();
    started = null;
    expect(File('${home.path}/relay.pid').existsSync(), isFalse);
    expect(tokenFile.existsSync(), isTrue, reason: 'a restart keeps its URL');
  });

  test('a second start reads the token the first one minted', () async {
    final first = await startRelay(args(), out: out, err: err);
    final token = File('${home.path}/relay.token').readAsStringSync();
    await first.relay!.stop();

    final second = await startRelay(args(), out: out, err: err);
    started = second.relay;
    expect(File('${home.path}/relay.token').readAsStringSync(), token);
    final base = 'http://127.0.0.1:${started!.port}';
    expect(await status(Uri.parse('$base/k/${token.trim()}/healthz')), 200);
  });

  test('a token file that holds no usable token refuses the start', () async {
    File('${home.path}/relay.token').writeAsStringSync('short');
    final result = await startRelay(args(), out: out, err: err);
    started = result.relay;
    expect(result.relay, isNull);
    expect(result.exitCode, 6);
    expect(err.text.toString(), contains('token'));
    expect(err.text.toString(), isNot(contains('short')));
    expect(File('${home.path}/relay.pid').existsSync(), isFalse);
  });

  test('missing or junk arguments are a usage error', () async {
    for (final bad in [
      <String>[],
      ['--port=8787'],
      ['--port=nope', '--token-file=a', '--pid-file=b'],
      ['--port=70000', '--token-file=a', '--pid-file=b'],
      [...args(), '--token=on-the-command-line'],
    ]) {
      final result = await startRelay(bad, out: out, err: err);
      expect(result.relay, isNull, reason: '$bad');
      expect(result.exitCode, 2, reason: '$bad');
    }
    expect(err.text.toString(), contains('karmashala_host relay'));
  });

  test('a busy port is said in words', () async {
    final squatter = await ServerSocket.bind('127.0.0.1', 0);
    addTearDown(squatter.close);
    final result = await startRelay(
      args(port: squatter.port),
      out: out,
      err: err,
    );
    started = result.relay;
    expect(result.relay, isNull);
    expect(result.exitCode, 5);
    expect(err.text.toString(), contains('${squatter.port}'));
    expect(File('${home.path}/relay.pid').existsSync(), isFalse);
  });

  test('the cli knows the command and lists it', () async {
    expect(
      await runHostCli(
        ['--help'],
        environment: kNowhereEnvironment,
        out: out,
        err: err,
      ),
      0,
    );
    expect(out.text.toString(), contains('karmashala_host relay'));
    expect(
      await runHostCli(
        ['relay', '--help'],
        environment: kNowhereEnvironment,
        out: out,
        err: err,
      ),
      0,
    );
    expect(
      await runHostCli(
        ['relay'],
        environment: kNowhereEnvironment,
        out: out,
        err: err,
      ),
      2,
    );
  });
}
