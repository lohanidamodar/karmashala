/// `serve` and its store: the app's file at `--data-dir`, never one of its own.
/// Run in-process on temp directories, never on anyone's real host.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// An [IOSink] that keeps what it was given and completes [banner] once the
/// daemon has said it is serving.
class _Sink implements IOSink {
  final StringBuffer text = StringBuffer();
  final banner = Completer<void>();

  void _saw() {
    if (!banner.isCompleted && text.toString().contains('restored ')) {
      banner.complete();
    }
  }

  @override
  Encoding encoding = utf8;

  @override
  void write(Object? object) {
    text.write(object);
    _saw();
  }

  @override
  void writeln([Object? object = '']) {
    text.writeln(object);
    _saw();
  }

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

void main() {
  late Directory root;
  late _Sink out;
  late _Sink err;

  setUp(() {
    root = Directory.systemTemp.createTempSync('kh-store');
    out = _Sink();
    err = _Sink();
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('without --data-dir it refuses before touching anything', () async {
    final hostDir = Directory(p.join(root.path, 'host'));
    final code = await runServe(
      ['--companion-port=0'],
      out: out,
      err: err,
      paths: HostPaths(hostDir),
    );
    expect(code, 2);
    expect(err.text.toString(), contains('--data-dir=<dir>'));
    expect(hostDir.existsSync(), isFalse);
  });

  test('--data-dir is read absolute, and empty is missing', () {
    expect(dataDirectoryOf(['--data-dir=']), isNull);
    expect(dataDirectoryOf(['--companion-port=0']), isNull);
    expect(dataDirectoryOf(['--data-dir=rel']), p.absolute('rel'));
  });

  test('the store is <data-dir>/karmashala.sqlite; the host directory keeps '
      'none of its own', () async {
    final hostDir = Directory(p.join(root.path, 'host'));
    final dataDir = Directory(p.join(root.path, 'data'));
    final stop = Completer<void>();
    final serving = runServe(
      ['--companion-port=0', '--data-dir=${dataDir.path}'],
      out: out,
      err: err,
      paths: HostPaths(hostDir),
      until: stop.future,
    );
    await Future.any([
      out.banner.future,
      serving.then((code) => fail('serve exited $code: ${err.text}')),
    ]);
    stop.complete();
    expect(await serving, 0, reason: '${err.text}');

    expect(
      File(p.join(dataDir.path, 'karmashala.sqlite')).existsSync(),
      isTrue,
    );
    expect(
      File(p.join(hostDir.path, 'karmashala.sqlite')).existsSync(),
      isFalse,
    );
    expect(
      out.text.toString(),
      contains('store ${p.join(dataDir.path, 'karmashala.sqlite')}'),
    );
  }, testOn: 'mac-os || linux');
}
