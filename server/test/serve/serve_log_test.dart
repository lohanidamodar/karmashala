/// What a detached `serve` leaves in `<data>/logs/server.log`: run in-process
/// with sinks nobody reads, as when the app that started it has gone.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('kh-serve-log'));
  tearDown(() => root.deleteSync(recursive: true));

  File logOf(Directory data) => File(p.join(data.path, 'logs', 'server.log'));

  test('a serve with no terminal writes its start-up line first, even when '
      'it then refuses', () async {
    final data = Directory(p.join(root.path, 'data'));
    final code = await runServe(
      ['--data-dir=${data.path}', '--companion-port=not-a-port'],
      out: _Sink(dead: true),
      err: _Sink(dead: true),
      paths: HostPaths(Directory(p.join(root.path, 'host'))),
    );
    expect(code, 2);
    final lines = logOf(data).readAsLinesSync();
    expect(lines.first, contains('serve $kHostVersion started; data '));
    expect(lines.any((l) => l.contains('not-a-port')), isTrue);
  });

  test('what the server\'s libraries log through package:logging is filed '
      'too', () async {
    final data = Directory(p.join(root.path, 'data'));
    final out = _Sink();
    final stop = Completer<void>();
    final serving = runServe(
      ['--companion-port=0', '--mcp-port=0', '--data-dir=${data.path}'],
      out: out,
      err: _Sink(dead: true),
      paths: HostPaths(Directory(p.join(root.path, 'host'))),
      until: stop.future,
      agentScanDelay: const Duration(hours: 1),
    );
    await Future.any([
      out.banner.future,
      serving.then((code) => fail('serve exited $code')),
    ]);
    Logger('karmashala.probe').warning('a line no sink was handed');
    stop.complete();
    expect(await serving, 0);
    expect(
      logOf(data).readAsStringSync(),
      contains('karmashala.probe: a line no sink was handed'),
    );
  }, timeout: const Timeout(Duration(minutes: 2)));
}

/// A sink that keeps what it is given and completes [banner] once the daemon
/// says it is serving; [dead] is a reader that has gone.
class _Sink implements IOSink {
  _Sink({this.dead = false});

  final bool dead;
  final StringBuffer text = StringBuffer();
  final banner = Completer<void>();

  void _take(Object? object) {
    if (dead) throw const FileSystemException('broken pipe');
    text.write(object);
    if (!banner.isCompleted && text.toString().contains('restored ')) {
      banner.complete();
    }
  }

  @override
  Encoding encoding = utf8;

  @override
  void write(Object? object) => _take(object);

  @override
  void writeln([Object? object = '']) => _take('$object\n');

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _take(objects.join(separator));

  @override
  void writeCharCode(int charCode) => _take(String.fromCharCode(charCode));

  @override
  void add(List<int> data) => _take(utf8.decode(data));

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
