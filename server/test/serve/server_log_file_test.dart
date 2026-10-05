/// The server's log file: every line `serve` writes is also kept, redacted,
/// in its data folder, so a detached server leaves something to read.
library;

import 'dart:convert';
import 'dart:io';

import 'package:karmashala_host/src/serve/server_log_file.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('kh-log'));
  tearDown(() => root.deleteSync(recursive: true));

  test('lies in <data>/logs/server.log', () {
    expect(
      ServerLogFile(root.path).file.path,
      p.join(root.path, 'logs', 'server.log'),
    );
  });

  test('a line written to a filed sink reaches both the sink and the file, '
      'redacted there, and a part line waits for its end', () async {
    final log = ServerLogFile(root.path);
    final inner = _Sink();
    final err = FiledSink(inner, log, channel: 'err');
    err.write('agents: ');
    err.writeln('2 found');
    err.writeln('auth Bearer abcdefghijklmnop failed');
    err.write('not yet ended');
    await log.close();

    expect(inner.text.toString(), contains('agents: 2 found\n'));
    final lines = log.file.readAsLinesSync();
    expect(lines, hasLength(2));
    expect(lines[0], endsWith('err: agents: 2 found'));
    expect(lines[1], contains('Bearer [redacted:token]'));
    expect(lines[1], isNot(contains('abcdefghijklmnop')));
  });

  test('a line said before the data folder is known is filed once it is',
      () async {
    final log = ServerLogFile();
    FiledSink(_Sink(), log, channel: 'err').writeln('early');
    log.open(root.path);
    await log.close();
    expect(log.file.readAsStringSync(), contains('err: early'));
  });

  test('a sink nobody reads still files its lines', () async {
    final log = ServerLogFile(root.path);
    final out = FiledSink(_Sink(dead: true), log, channel: 'out');
    out.writeln('restored 0 session(s)');
    await log.close();
    expect(log.file.readAsStringSync(), contains('restored 0 session(s)'));
  });

  test('rotates at its size, keeping a few generations', () async {
    final log = ServerLogFile(root.path, 200, 3);
    final err = FiledSink(_Sink(), log, channel: 'err');
    for (var i = 0; i < 30; i++) {
      err.writeln('line $i ${'x' * 40}');
      await log.flush();
    }
    await log.close();
    final names = root
        .listSync(recursive: true)
        .whereType<File>()
        .map((f) => p.basename(f.path))
        .toSet();
    // The live file is renamed away the moment it passes the size.
    expect(
      names,
      allOf(
        containsAll(['server.1.log', 'server.2.log']),
        everyElement(isIn(['server.log', 'server.1.log', 'server.2.log'])),
      ),
    );
  });
}

class _Sink implements IOSink {
  _Sink({this.dead = false});

  final bool dead;
  final StringBuffer text = StringBuffer();

  void _take(Object? object) {
    if (dead) throw const FileSystemException('broken pipe');
    text.write(object);
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
