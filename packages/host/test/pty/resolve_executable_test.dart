import 'dart:io';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:test/test.dart';

/// argv[0] as `execvp` would find it. Neither `posix_spawn` nor the macOS
/// shim's `execv` searches PATH, so a project check written `test -f
/// README.md` ran as nothing and failed with exit 127 (2026-09-25).
void main() {
  late Directory bin;
  late Directory other;

  setUp(() {
    bin = Directory.systemTemp.createTempSync('karmashala-bin');
    other = Directory.systemTemp.createTempSync('karmashala-other');
  });
  tearDown(() {
    bin.deleteSync(recursive: true);
    other.deleteSync(recursive: true);
  });

  File tool(Directory where, String name, {bool executable = true}) {
    final file = File('${where.path}/$name')..writeAsStringSync('#!/bin/sh\n');
    if (executable) Process.runSync('chmod', ['+x', file.path]);
    return file;
  }

  test('a bare name is found on the child\'s PATH, first match wins', () {
    tool(bin, 'flutter');
    tool(other, 'flutter');
    expect(
      resolveExecutable('flutter', {'PATH': '${bin.path}:${other.path}'}),
      '${bin.path}/flutter',
    );
  });

  test('a file without an execute bit, or a directory, is passed over', () {
    tool(bin, 'npm', executable: false);
    Directory('${bin.path}/dart').createSync();
    tool(other, 'npm');
    tool(other, 'dart');
    final env = {'PATH': '${bin.path}:${other.path}'};
    expect(resolveExecutable('npm', env), '${other.path}/npm');
    expect(resolveExecutable('dart', env), '${other.path}/dart');
  });

  test('a path is taken as given', () {
    expect(
      resolveExecutable('/usr/local/bin/claude', const {}),
      '/usr/local/bin/claude',
    );
    expect(resolveExecutable('./gradlew', const {}), './gradlew');
  });

  test('empty and relative PATH entries are not searched', () {
    tool(bin, 'make');
    expect(
      () => resolveExecutable('make', const {'PATH': ':relative'}),
      throwsA(isA<PtyException>()),
    );
  });

  test('a missing command says what was searched', () {
    expect(
      () => resolveExecutable('nosuchtool', {'PATH': bin.path}),
      throwsA(
        isA<PtyException>().having(
          (e) => e.message,
          'message',
          '"nosuchtool" was not found on PATH (${bin.path})',
        ),
      ),
    );
    expect(
      () => resolveExecutable('test', const {}),
      throwsA(
        isA<PtyException>().having(
          (e) => e.message,
          'message',
          contains('no PATH to search'),
        ),
      ),
    );
  });

  test('the real `test` on this machine resolves', () {
    if (Platform.isWindows) return;
    expect(
      resolveExecutable('test', const {'PATH': '/usr/bin:/bin'}),
      anyOf('/usr/bin/test', '/bin/test'),
    );
  });
}
