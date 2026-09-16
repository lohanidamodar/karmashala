import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../probe_report.dart';
import 'conpty.dart';
import 'posix_pty.dart';
import 'pty.dart';
import 'pty_platform.dart';

/// Asks a deployed host whether its pty layer works: spawn, echo, resize, exit
/// code. One `step ok/FAIL` line each, non-zero on the first failure. Every step
/// counts bytes and the deadline is a failure bound, never a poll.
Future<int> runPtyProbe({IOSink? out}) async {
  final sink = out ?? stdout;
  var failures = 0;
  void step(String name, bool ok, [String detail = '']) {
    if (!ok) failures++;
    sink.writeln(probeStep(name, ok, detail));
  }

  final PtyPlatform platform;
  try {
    platform = resolvePtyPlatform();
  } on PtyException catch (e) {
    sink.writeln('FAIL pty layer  ${e.message}');
    return 1;
  }
  sink.writeln(probeHeader());
  sink.writeln('pty-lib   ${platform.library}');

  final launcher = platform.launcher;
  if (launcher is PosixPtyLauncher) {
    sink.writeln('forkpty   ${launcher.providesForkpty ? 'resolvable' : 'absent'} (never called)');
    sink.writeln('chdir     ${launcher.honoursWorkingDirectory ? 'supported' : 'unsupported'}');
  }
  if (launcher is ConPtyLauncher) {
    // Windows has no signals: said here rather than found in an exit code that
    // is not 128 + anything.
    sink.writeln('signals   none (kill terminates the process tree)');
  }

  final shell = _probeShell();
  PtyHandle handle;
  try {
    handle = launcher.start(shell.request);
  } on PtyException catch (e) {
    step('spawn ${shell.request.argv.first}', false, '$e');
    return 1;
  }
  step('spawn ${shell.request.argv.first}', true, 'pid ${handle.pid}');

  final reader = _ByteWatcher(handle.output);
  try {
    handle.write(_ascii(shell.echoCommand));
    final echoed = await reader.until('karmashala');
    step('echo round-trip', echoed, 'saw ${reader.length} bytes');

    handle.resize(100, 30);
    handle.write(_ascii(shell.sizeCommand));
    final resized = await reader.until(shell.expectedSize);
    step(
      'resize -> reported size',
      resized,
      resized ? shell.expectedSize : 'saw ${reader.tail(60)}',
    );

    handle.write(_ascii(shell.exitCommand));
    final code = await handle.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () => -1,
    );
    step('exit code', code == 7, 'got $code');
  } finally {
    await handle.close();
  }
  sink.writeln(failures == 0 ? 'PROBE OK' : 'PROBE FAILED ($failures)');
  return failures == 0 ? 0 : 1;
}

/// What to start and what to type into it, per platform.
class _ProbeShell {
  const _ProbeShell({
    required this.request,
    required this.echoCommand,
    required this.sizeCommand,
    required this.expectedSize,
    required this.exitCommand,
  });

  final PtySpawnRequest request;

  /// The command line must not contain the answer, or the tty's echo of what
  /// was typed passes for the child having run it.
  final String echoCommand;
  final String sizeCommand;
  final String expectedSize;
  final String exitCommand;
}

_ProbeShell _probeShell() {
  if (Platform.isWindows) {
    return _ProbeShell(
      request: PtySpawnRequest(
        argv: ['powershell.exe', '-NoLogo', '-NoProfile'],
        workingDirectory: Directory.systemTemp.path,
        environment: const {'TERM': 'xterm-256color'},
        columns: 80,
        rows: 24,
      ),
      echoCommand: "Write-Output ('karma'+'shala')\r\n",
      // Does the process learn the size it was resized to?
      sizeCommand: 'Write-Output "\$(\$Host.UI.RawUI.WindowSize.Height) '
          '\$(\$Host.UI.RawUI.WindowSize.Width)"\r\n',
      expectedSize: '30 100',
      exitCommand: 'exit 7\r\n',
    );
  }
  return const _ProbeShell(
    request: PtySpawnRequest(
      argv: ['/bin/sh'],
      workingDirectory: '/tmp',
      environment: {'TERM': 'dumb', 'PATH': '/usr/bin:/bin', 'PS1': r'$ '},
      columns: 80,
      rows: 24,
    ),
    // `karma''shala` echoes back with the quotes and prints without them, so a
    // match proves the child ran the command rather than the tty echoing it.
    echoCommand: "echo karma''shala\n",
    sizeCommand: 'stty size\n',
    expectedSize: '30 100',
    exitCommand: 'exit 7\n',
  );
}

Uint8List _ascii(String s) => Uint8List.fromList(utf8.encode(s));

/// Accumulates the child's bytes so a check can ask "has this appeared yet",
/// which is a count of bytes seen and not a sleep.
class _ByteWatcher {
  _ByteWatcher(Stream<Uint8List> source) {
    _subscription = source.listen((chunk) {
      _buffer.write(utf8.decode(chunk, allowMalformed: true));
      _check();
    }, onDone: _check);
  }

  final _buffer = StringBuffer();
  late final StreamSubscription<Uint8List> _subscription;
  String? _wanted;
  Completer<bool>? _waiting;

  int get length => _buffer.length;
  String tail(int n) {
    final s = _buffer.toString();
    return s.length <= n ? s : s.substring(s.length - n);
  }

  Future<bool> until(String needle, {Duration limit = const Duration(seconds: 10)}) {
    if (_buffer.toString().contains(needle)) return Future.value(true);
    _wanted = needle;
    final completer = _waiting = Completer<bool>();
    return completer.future.timeout(limit, onTimeout: () {
      _wanted = null;
      _waiting = null;
      return false;
    });
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

  Future<void> cancel() => _subscription.cancel();
}
