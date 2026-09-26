@TestOn('posix')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A pty released by [Pty.destroy] gives its file descriptors back.
///
/// Compiles the vendored native sources with a harness and runs them, because
/// the plugin's dylib exists only inside a built app bundle — `flutter test`
/// cannot load it, so there is no way to reach this code from Dart.
///
/// What it guards: upstream `flutter_pty` 0.4.2 has no teardown at all, and
/// leaked **two** descriptors per pty — the master, because `read_loop` returned
/// without closing it, and the slave, because `pty_forkpty` only ever handed it
/// back through an out-param that `pty_create` passes as NULL. Measured on a
/// real session: 10 stranded descriptors after 6 closed panes. macOS gives a
/// Finder-launched app a soft limit of 256, so a long day of opening panes ends
/// with the app unable to open files or spawn anything.
void main() {
  test('destroying a pty releases its descriptors', () async {
    final cc = await _which('cc');
    if (cc == null) {
      markTestSkipped('no C compiler on PATH');
      return;
    }

    final work = await Directory.systemTemp.createTemp('pty_fd_lifecycle');
    addTearDown(() => work.delete(recursive: true));
    final binary = '${work.path}/harness';

    const src = '../packages/flutter_pty/src';
    final build = await Process.run(cc, [
      '-O0',
      '-I',
      src,
      '../packages/flutter_pty/test/fd_lifecycle_harness.c',
      '$src/flutter_pty_unix.c',
      '$src/forkpty.c',
      '$src/include/dart_api_dl.c',
      '-o',
      binary,
    ]);
    expect(
      build.exitCode,
      0,
      reason: 'harness did not build:\n${build.stderr}',
    );

    // Enough ptys that a per-pty leak is unmistakable against the couple of
    // descriptors of slack the harness allows for unrelated lazy opens.
    final run = await Process.run(binary, ['64']);
    expect(
      run.exitCode,
      0,
      reason:
          'descriptors were not released — ${run.stdout.toString().trim()}. '
          'Every pty that ends must give back both its master and its slave.',
    );
    expect(run.stdout, contains('iterations=64'));
  }, timeout: const Timeout(Duration(minutes: 2)));
}

Future<String?> _which(String command) async {
  final found = await Process.run('which', [command]);
  if (found.exitCode != 0) return null;
  final path = found.stdout.toString().trim();
  return path.isEmpty ? null : path;
}
