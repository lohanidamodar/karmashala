import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'libc.dart';
import 'posix_pty.dart';
import 'pty.dart';

/// The stage-zero proof, kept as a subcommand rather than a throwaway script so
/// a deployed host can be asked, on the machine that matters, whether its pty
/// layer actually works. Every step counts bytes; the deadline is a failure
/// bound, never a poll.
///
/// Prints one `step ok/FAIL` line per check and exits non-zero on the first
/// failure, so `karmashala_host probe-pty` is quotable evidence.
Future<int> runPtyProbe({IOSink? out}) async {
  final sink = out ?? stdout;
  var failures = 0;
  void step(String name, bool ok, [String detail = '']) {
    if (!ok) failures++;
    sink.writeln('${ok ? 'ok  ' : 'FAIL'} $name${detail.isEmpty ? '' : '  $detail'}');
  }

  final Libc libc;
  try {
    libc = Libc.open();
  } on ArgumentError catch (e) {
    sink.writeln('FAIL libc  $e');
    return 1;
  }
  sink.writeln('host      ${Platform.operatingSystem} ${_arch()}');
  sink.writeln('pty-lib   ${libc.ptySymbolLibrary} (${libc.ptySymbolSource.name})');
  sink.writeln('forkpty   ${libc.providesForkpty ? 'resolvable' : 'absent'} (never called)');

  final launcher = PosixPtyLauncher(libc: libc);
  sink.writeln('chdir     ${launcher.honoursWorkingDirectory ? 'supported' : 'unsupported'}');

  PtyHandle handle;
  try {
    handle = launcher.start(
      const PtySpawnRequest(
        argv: ['/bin/sh'],
        workingDirectory: '/tmp',
        environment: {'TERM': 'dumb', 'PATH': '/usr/bin:/bin', 'PS1': r'$ '},
        columns: 80,
        rows: 24,
      ),
    );
  } on PtyException catch (e) {
    step('spawn /bin/sh', false, '$e');
    return 1;
  }
  step('spawn /bin/sh', true, 'pid ${handle.pid}');

  final reader = _ByteWatcher(handle.output);
  try {
    // `karma''shala` echoes back with the quotes and prints without them, so a
    // match proves the child ran the command rather than the tty echoing it.
    handle.write(_ascii("echo karma''shala\n"));
    final echoed = await reader.until('karmashala\r\n');
    step('echo round-trip', echoed, 'saw ${reader.length} bytes');

    handle.resize(100, 30);
    handle.write(_ascii('stty size\n'));
    final resized = await reader.until('30 100');
    step('resize -> stty size', resized, resized ? '30 100' : 'saw ${reader.tail(60)}');

    handle.write(_ascii('exit 7\n'));
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

String _arch() {
  final v = Platform.version;
  final match = RegExp(r'"[a-z]+_([a-z0-9]+)"').firstMatch(v);
  return match?.group(1) ?? 'unknown';
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
