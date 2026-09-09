@Tags(['live'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:test/test.dart';

/// The ConPTY layer against a real `cmd.exe`, which is the only thing that can
/// answer whether the FFI struct layouts and the pseudoconsole handshake are
/// right: every layer above the pty is already covered by the fake, and a fake
/// cannot get `STARTUPINFOEXW` wrong.
///
/// Excluded from the ordinary gate for the same reason `live-wsl` is — it
/// spawns real processes and its failures are the machine's as often as ours.
/// Run it deliberately:
///
///   dart test --tags=live test/pty/conpty_live_test.dart
void main() {
  if (!Platform.isWindows) {
    // Not a skip with a reason invented here: a ConPTY does not exist off
    // Windows, so there is nothing to measure rather than something we chose
    // not to.
    test('ConPTY is a Windows pty layer', () {}, skip: 'not Windows');
    return;
  }

  late ConPtyLauncher launcher;

  setUp(() => launcher = ConPtyLauncher());

  test('kernel32 carries the three pseudoconsole entry points', () {
    expect(launcher.providesPseudoConsole, isTrue);
    expect(launcher.ptyLibrary, 'kernel32.dll');
  });

  test('cmd.exe starts, echoes what it ran, and reports its exit code', () async {
    final pty = launcher.start(
      PtySpawnRequest(
        argv: const ['cmd.exe'],
        workingDirectory: Directory.systemTemp.path,
        environment: const {'TERM': 'xterm-256color'},
        columns: 80,
        rows: 24,
      ),
    );
    addTearDown(pty.close);
    expect(pty.pid, greaterThan(0));

    final seen = _Transcript(pty.output);
    // Assembled from two variables so the line `cmd` echoes back does not
    // itself contain the answer: a match proves the child ran it.
    pty.write(_type('set A=karma'));
    pty.write(_type('set B=shala'));
    pty.write(_type('echo %A%%B%'));
    expect(await seen.contains('karmashala'), isTrue, reason: seen.tail(400));

    pty.write(_type('exit 7'));
    final code = await pty.exitCode.timeout(const Duration(seconds: 15));
    expect(code, 7);
  });

  test('a resize reaches the process, not just the pseudoconsole', () async {
    final pty = launcher.start(
      PtySpawnRequest(
        argv: const ['cmd.exe'],
        workingDirectory: Directory.systemTemp.path,
        columns: 80,
        rows: 24,
      ),
    );
    addTearDown(pty.close);
    final seen = _Transcript(pty.output);

    pty.resize(100, 30);
    // `mode con` reports the console the child is attached to, which is the
    // pseudoconsole — the Windows counterpart of `stty size` and the same
    // question `live_pane_resize_test.dart` asks a real pane.
    pty.write(_type('mode con'));
    expect(await seen.contains('100'), isTrue, reason: seen.tail(400));

    pty.write(_type('exit'));
    await pty.exitCode.timeout(const Duration(seconds: 15));
  });

  test('the environment is layered over this process, not replacing it', () async {
    final pty = launcher.start(
      PtySpawnRequest(
        argv: const ['cmd.exe'],
        workingDirectory: Directory.systemTemp.path,
        environment: const {'KARMASHALA_PROBE': 'layered'},
        columns: 80,
        rows: 24,
      ),
    );
    addTearDown(pty.close);
    final seen = _Transcript(pty.output);

    pty.write(_type('echo %KARMASHALA_PROBE%'));
    expect(await seen.contains('layered'), isTrue, reason: seen.tail(400));
    // SystemRoot is what a replaced block would have removed, and without it a
    // Windows child cannot load a DLL at all.
    pty.write(_type('if defined SystemRoot echo ROOT-KEPT'));
    expect(await seen.contains('ROOT-KEPT'), isTrue, reason: seen.tail(400));

    pty.write(_type('exit'));
    await pty.exitCode.timeout(const Duration(seconds: 15));
  });

  test('kill ends the shell and the child it started', () async {
    final pty = launcher.start(
      PtySpawnRequest(
        argv: const ['cmd.exe'],
        workingDirectory: Directory.systemTemp.path,
        columns: 80,
        rows: 24,
      ),
    );
    addTearDown(pty.close);
    final seen = _Transcript(pty.output);

    // A grandchild that would outlive a shallow kill: `pause` waits for input
    // that will never come.
    pty.write(_type('cmd.exe /c pause'));
    expect(await seen.contains('any key'), isTrue, reason: seen.tail(400));

    pty.kill();
    // The exit code is whatever TerminateProcess set — the point of the
    // assertion is that the session ends at all, which it cannot do while a
    // grandchild holds the pseudoconsole.
    await pty.exitCode.timeout(const Duration(seconds: 15));
  });
}

Uint8List _type(String line) => Uint8List.fromList(utf8.encode('$line\r\n'));

/// Everything the child has written, and a way to wait for a substring by
/// counting bytes rather than sleeping for them.
class _Transcript {
  _Transcript(Stream<Uint8List> source) {
    source.listen((chunk) {
      _buffer.write(utf8.decode(chunk, allowMalformed: true));
      _check();
    }, onDone: _check);
  }

  final _buffer = StringBuffer();
  String? _wanted;
  Completer<bool>? _waiting;

  String tail(int n) {
    final s = _buffer.toString();
    return s.length <= n ? s : s.substring(s.length - n);
  }

  Future<bool> contains(String needle, {Duration within = const Duration(seconds: 15)}) {
    if (_buffer.toString().contains(needle)) return Future.value(true);
    _wanted = needle;
    final completer = _waiting = Completer<bool>();
    // A failure bound, not a poll: nothing here wakes up to look.
    return completer.future.timeout(within, onTimeout: () => false);
  }

  void _check() {
    final wanted = _wanted;
    final waiting = _waiting;
    if (wanted == null || waiting == null || waiting.isCompleted) return;
    if (_buffer.toString().contains(wanted)) {
      _wanted = null;
      _waiting = null;
      waiting.complete(true);
    }
  }
}
