import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/pty/libc.dart';

/// Spawns on a real kernel, many times and many at once, and prints one JSON
/// object: each scenario's name to `"ok"` or what went wrong.
///
/// A process of its own, not the test's: `dart test` keeps a compiler child
/// alive, and while any `dart:io` child lives, `dart:io`'s exit handler reaps
/// *every* child of the process — a pty's included — and throws the code away.
/// Here no `dart:io` process runs until the last scenario, which is about
/// exactly that.
Future<void> main() async {
  final results = <String, String>{};
  final dir = Directory.systemTemp.createTempSync('pty-battery');
  File('${dir.path}/README.md').writeAsStringSync('x');
  try {
    for (final (name, scenario) in <(String, Future<void> Function(String))>[
      ('sequential', _sequential),
      ('concurrent', _concurrent),
      ('inheritance', _inheritance),
      ('closeWhileHeld', _closeWhileHeld),
      ('alongsideDartIo', _alongsideDartIo),
    ]) {
      try {
        await scenario(dir.path).timeout(const Duration(seconds: 60));
        results[name] = 'ok';
      } on Object catch (error) {
        results[name] = '$error';
      }
    }
  } finally {
    dir.deleteSync(recursive: true);
  }
  stdout.writeln(jsonEncode(results));
  await stdout.flush();
  exit(0);
}

final _launcher = PosixPtyLauncher();
final _libc = Libc.open();

/// This process's open descriptors, asked of the kernel one by one.
Set<int> _openFds() => {
  for (var fd = 0; fd < 1024; fd++)
    if (_libc.fcntl(fd, kFGetFd, 0) >= 0) fd,
};

void _check(bool holds, String what) {
  if (!holds) throw StateError(what);
}

Future<(int, String)> _run(List<String> argv, {String? cwd}) async {
  final pty = _launcher.start(
    PtySpawnRequest(argv: argv, workingDirectory: cwd),
  );
  final said = StringBuffer();
  final done = pty.output
      .listen((bytes) => said.write(utf8.decode(bytes, allowMalformed: true)))
      .asFuture<void>();
  final code = await pty.exitCode.timeout(const Duration(seconds: 10));
  await done.timeout(const Duration(seconds: 10));
  await pty.close();
  return (code, said.toString());
}

/// Many in a row, argv[0] bare and absolute: the real code each time, and
/// nothing left open here.
Future<void> _sequential(String dir) async {
  await _run(['true']);
  final before = _openFds();
  for (var i = 0; i < 20; i++) {
    final (found, _) = await _run(['test', '-f', 'README.md'], cwd: dir);
    _check(found == 0, 'spawn $i: `test -f README.md` said $found');
    final (missing, _) = await _run(['test', '-f', 'NOPE'], cwd: dir);
    _check(missing == 1, 'spawn $i: `test -f NOPE` said $missing');
    final (given, _) = await _run(['/bin/sh', '-c', 'exit 3'], cwd: dir);
    _check(given == 3, 'spawn $i: `/bin/sh -c "exit 3"` said $given');
  }
  final after = _openFds();
  _check(
    after.length == before.length,
    'left open: ${after.difference(before)}',
  );
}

/// Twenty-four alive at once: each reaped with its own code, none left behind,
/// and the spawning isolate never held.
Future<void> _concurrent(String dir) async {
  await _run(['true']);
  final before = _openFds();
  var longest = Duration.zero;
  final clock = Stopwatch()..start();
  var last = clock.elapsed;
  final ticker = Timer.periodic(const Duration(milliseconds: 5), (_) {
    final now = clock.elapsed;
    if (now - last > longest) longest = now - last;
    last = now;
  });
  try {
    final ptys = [
      for (var i = 0; i < 24; i++)
        _launcher.start(
          PtySpawnRequest(
            argv: i.isEven
                ? ['sh', '-c', 'sleep 0.3; exit ${i % 7}']
                : ['/bin/sh', '-c', 'sleep 0.3; exit ${i % 7}'],
            workingDirectory: dir,
          ),
        ),
    ];
    for (final pty in ptys) {
      pty.output.listen((_) {});
    }
    final codes = await Future.wait([for (final pty in ptys) pty.exitCode]);
    final wanted = [for (var i = 0; i < 24; i++) i % 7];
    _check('$codes' == '$wanted', 'codes $codes, wanted $wanted');
    for (final pty in ptys) {
      await pty.close();
    }
    for (final pty in ptys) {
      // Signal 0 is not offered, so SIGCONT: harmless, false when gone —
      // and a zombie nobody reaped is still there.
      _check(
        !Process.killPid(pty.pid, ProcessSignal.sigcont),
        'pid ${pty.pid} was never reaped',
      );
    }
  } finally {
    ticker.cancel();
  }
  _check(
    longest < const Duration(milliseconds: 500),
    'the spawning isolate went ${longest.inMilliseconds}ms without a turn',
  );
  final after = _openFds();
  _check(
    after.length == before.length,
    'left open: ${after.difference(before)}',
  );
}

/// A child's descriptors are the same with no session open as with six: no
/// sibling's master reaches it.
Future<void> _inheritance(String dir) async {
  Future<String> childFds() async {
    final (code, said) = await _run(['sh', '-c', 'ls /dev/fd']);
    _check(code == 0, '`ls /dev/fd` said $code');
    return (said.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList()
          ..sort())
        .join(' ');
  }

  final alone = await childFds();
  final open = [
    for (var i = 0; i < 6; i++)
      _launcher.start(const PtySpawnRequest(argv: ['sleep', '30'])),
  ];
  try {
    for (final pty in open) {
      pty.output.listen((_) {});
    }
    final beside = await childFds();
    _check(beside == alone, 'alone "$alone", beside six sessions "$beside"');
  } finally {
    for (final pty in open) {
      pty.kill(9);
      await pty.exitCode;
      await pty.close();
    }
  }
}

/// close() while the child still holds the slave: the reader lets go and the
/// master is closed within a poll, by the reader, not under it.
Future<void> _closeWhileHeld(String dir) async {
  await _run(['true']);
  final before = _openFds();
  final pty = _launcher.start(
    const PtySpawnRequest(argv: ['sh', '-c', 'trap "" HUP; sleep 30']),
  );
  pty.output.listen((_) {});
  await Future<void>.delayed(const Duration(milliseconds: 300));
  await pty.close();
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (_openFds().length > before.length &&
      DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  final after = _openFds();
  Process.killPid(pty.pid, ProcessSignal.sigkill);
  _check(
    after.length == before.length,
    'left open: ${after.difference(before)}',
  );
}

/// Spawning while another isolate starts `dart:io` processes: `dart:io` forks
/// from its own thread, marks its pipes close-on-exec only after `pipe()`
/// returns, and reaps every child while one of its own lives — so a code may
/// be lost here, but no session may fail to end and nothing may be left open.
Future<void> _alongsideDartIo(String dir) async {
  await _run(['true']);
  // `dart:io` keeps a descriptor of its own once it has run a process.
  await Process.run('/bin/sh', ['-c', 'exit 0']);
  final before = _openFds();
  final other = Isolate.run(() async {
    for (var i = 0; i < 20; i++) {
      final result = await Process.run('/bin/sh', ['-c', 'exit 0']);
      if (result.exitCode != 0) return false;
    }
    return true;
  });
  for (var i = 0; i < 20; i++) {
    final pty = _launcher.start(
      PtySpawnRequest(
        argv: const ['test', '-f', 'README.md'],
        workingDirectory: dir,
      ),
    );
    pty.output.listen((_) {});
    await pty.exitCode.timeout(const Duration(seconds: 10));
    await pty.close();
  }
  _check(await other, 'a dart:io process failed');
  final after = _openFds();
  _check(
    after.length == before.length,
    'left open: ${after.difference(before)}',
  );
}
