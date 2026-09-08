@Tags(['live-wsl'])
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_pty/flutter_pty.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/terminal/data/pty_launch.dart';
import 'package:karmashala/src/features/terminal/data/process_shutdown.dart';
import 'package:karmashala/src/features/terminal/domain/enter_key_encoding.dart';
import 'package:karmashala/src/features/terminal/domain/launch_context.dart';
import 'package:xterm2/xterm.dart';

/// **Does an escape sequence this app writes reach the process in a WSL pane in
/// one piece?**
///
/// It has to, and nothing above the PTY can tell. Every navigation key is
/// `ESC` followed by a tail, and the byte parser Codex and every other
/// crossterm program uses on Linux resolves an `ESC` the moment a `read()` ends
/// on it: it emits a lone `Esc` key and then reads the tail as *text*. So a
/// read boundary one byte after the `ESC` turns End into a literal `[F` in the
/// composer, which is exactly what the owner reported on 2026-09-08. Nothing in
/// this repository can see that; only the far end of a real chain can.
///
/// **Measured 2026-09-09 on Windows 10.0.26200 against `archlinux`, and the
/// launch form is the whole story.** Through the launch this app builds —
/// `cmd.exe /c wsl.exe -d <distro> …`, [wrapForPty] — every sequence arrives
/// whole:
///
/// ```txt
/// End, one write            40/40 read as one `\x1b[F`
/// End ×10, no gap           200 presses, 0 reads ended on a bare ESC
/// End into a pane repainting at 125 Hz   40/40 whole
/// Home, Right, Up, Delete, F5, SS3 forms 3/3 each, whole
/// ```
///
/// Through the launch it *used* to build — `Pty.start('wsl.exe', …)`, whose
/// duplicated leading token (`pty_command_line_test.dart` explains it) makes
/// the distro's login shell exec a Windows `wsl.exe` back out through interop,
/// adding a second pty and a second relay — the same 40 presses arrive:
///
/// ```txt
/// whole `\x1b[F`            12/40
/// split `\x1b[` + `F`       20/40   harmless: the parser waits for the tail
/// split `\x1b` + `[F`        8/40   FATAL: `Esc`, then `[` and `F` as text
/// ```
///
/// Confirmed against real Codex in both shapes on the same day: through this
/// app's launch, Home put the caret at the start (`Xhello`); through the nested
/// one, the composer read `hello[HX`.
///
/// So the split is real, it is in that extra interop relay, and the app has not
/// been exposed to it since `fix/nested-wsl-launch` (2026-09-01). This test is
/// what stops that coming back without anybody noticing: `pty_command_line_test`
/// pins the command line, and this pins the property the command line is *for*.
///
/// The nested shape is measured here too, and **reports rather than asserts**.
/// Whether WSL's own relay chops a 3-byte write in two is the machine's
/// behaviour, not this app's, and failing on it would blame the wrong thing.
///
/// Skips itself where there is no WSL, no `python3` in it to read raw bytes
/// with, or no `flutter_pty.dll` to spawn a ConPTY — the same shape as
/// `live_wsl_prompt_test.dart`.
void main() {
  final probe = _probe();
  if (probe != null) {
    test('live WSL input boundary test is skipped', () {}, skip: probe);
    return;
  }
  final distro = _defaultDistro()!;
  _installProbe(distro);

  test('every key this app writes arrives in one read', () async {
    final reads = await _throughAppLaunch(distro);
    expect(reads.sent, isNotEmpty, reason: 'nothing was typed into the pane');

    // The bytes are the fork's business and are pinned elsewhere; what is
    // asserted here is only that whatever was written arrived undivided.
    for (final written in reads.sent) {
      expect(
        reads.reads,
        contains(written),
        reason:
            'the pane wrote $written as one call and no single read() in the '
            'distribution contained it. Reads: ${reads.reads}',
      );
    }
    // The one boundary that is fatal on its own, stated separately because it
    // is the failure mode rather than a consequence of it.
    expect(
      reads.reads.where((r) => r.endsWith('1b')),
      isEmpty,
      reason:
          'a read ended on a bare ESC; a crossterm program resolves that as '
          'the Esc key and types the tail. Reads: ${reads.reads}',
    );
  }, timeout: const Timeout(Duration(seconds: 180)));

  test('and the nested wsl.exe launch is measured, not asserted', () async {
    final reads = await _throughNestedLaunch(distro);
    final whole = reads.reads.where(_looksWhole).length;
    final fatal = reads.reads.where((r) => r.endsWith('1b')).length;
    // Printed rather than asserted: this is the shape the app deliberately does
    // not use, and what WSL's relay does with it is WSL's to change.
    printOnFailure('nested launch: $whole whole, $fatal ended on a bare ESC');
    stdout.writeln(
      'live_wsl_input_boundary: nested wsl.exe launch — '
      '${reads.reads.length} reads for ${reads.sent.length} writes, '
      '$whole whole, $fatal ended on a bare ESC (each of those is one key '
      'that would be typed as text). This is why the launch goes through '
      'cmd.exe.',
    );
  }, timeout: const Timeout(Duration(seconds: 180)));
}

const _probePath = '/tmp/karmashala_input_boundary_probe.py';
const _logPath = '/tmp/karmashala_input_boundary_log';
const _ready = 'KARMASHALA_BOUNDARY_READY';

/// What a pane wrote, and what the process in the distribution read back.
///
/// Both sides are hex, because two `List<int>`s with the same bytes are not
/// equal in Dart and every assertion here is about content.
class _Boundaries {
  const _Boundaries(this.sent, this.reads);

  /// One entry per `pty.write`.
  final List<String> sent;

  /// One entry per `read()` the process made, in order.
  final List<String> reads;
}

/// Whether a read is a complete escape sequence (or complete plain text) rather
/// than a fragment of one. Only used for the nested launch's report.
bool _looksWhole(String read) {
  if (read.isEmpty) return false;
  if (read.endsWith('1b')) return false;
  return !read.startsWith('1b') || read.length > 4;
}

/// A raw-mode reader that logs **every `read()` call**, which is the only place
/// the boundary is visible: by the time bytes reach a program's parser the call
/// they arrived on is what decides whether an `ESC` is resolved or held.
void _installProbe(String distro) {
  const script =
      '''
import os, sys, termios, time, tty
log = open(sys.argv[1], "w", buffering=1)
tty.setraw(0)
sys.stdout.write("$_ready\\r\\n")
sys.stdout.flush()
try:
    while True:
        data = os.read(0, 4096)
        if not data:
            break
        log.write("%d %s\\n" % (time.monotonic_ns() // 1000, data.hex()))
        if b"\\x04" in data:
            break
finally:
    log.close()
''';
  // `--exec` hands `wsl.exe` an argv byte for byte with no shell in the way,
  // so the script can simply be one of the arguments.
  final write = Process.runSync(
    'wsl.exe',
    [
      '-d',
      distro,
      '--exec',
      '/bin/sh',
      '-c',
      'printf %s "\$1" > $_probePath',
      'sh',
      script,
    ],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (write.exitCode != 0) {
    throw StateError('could not install the probe: ${write.stderr}');
  }
}

/// The navigation keys the report was about, driven through the app's own
/// input handler so the bytes are the ones a pane really sends.
const _keys = [
  TerminalKey.end,
  TerminalKey.home,
  TerminalKey.arrowRight,
  TerminalKey.arrowUp,
  TerminalKey.delete,
  TerminalKey.f5,
];

/// Through the launch this app builds for a WSL pane.
Future<_Boundaries> _throughAppLaunch(String distro) {
  final launch = wrapForPty(
    ShellCommand(
      executable: 'python3',
      arguments: [_probePath, _logPath],
      workingDirectory: '/tmp',
    ),
    LaunchContext.wsl(distro),
  );
  return _drive(
    distro,
    () => Pty.start(
      launch.executable,
      arguments: launch.arguments,
      environment: {...Platform.environment, ...launch.environment},
      rows: 34,
      columns: 120,
    ),
  );
}

/// Through the launch that used to be built: `wsl.exe` spawned directly, whose
/// duplicated leading token sends the pane back out through interop.
Future<_Boundaries> _throughNestedLaunch(String distro) => _drive(
  distro,
  () => Pty.start(
    'wsl.exe',
    arguments: [
      '-d',
      distro,
      '--cd',
      '/tmp',
      '-e',
      'python3',
      _probePath,
      _logPath,
    ],
    environment: Platform.environment,
    rows: 34,
    columns: 120,
  ),
  required: false,
);

/// Opens a pane on [start], types every key into it through a real [Terminal],
/// then reads back what the process on the far end saw.
///
/// [required] is false for the nested launch, which reaches its reader by
/// having the login shell exec a Windows PE through interop: with interop
/// unregistered that pane cannot start at all, and a *control* that reports
/// must not fail the run over the machine's own state.
Future<_Boundaries> _drive(
  String distro,
  Pty Function() start, {
  bool required = true,
}) async {
  await Process.run('wsl.exe', [
    '-d',
    distro,
    '--exec',
    '/bin/rm',
    '-f',
    _logPath,
  ]);
  final pty = start();
  final screen = StringBuffer();
  final sent = <String>[];
  final terminal = Terminal(maxLines: 200)..resize(120, 34);
  terminal.inputHandler = const KarmashalaInputHandler();
  terminal.onOutput = (data) {
    final bytes = const Utf8Encoder().convert(data);
    sent.add(_toHex(bytes));
    pty.write(Uint8List.fromList(bytes));
  };
  final subscription = pty.output.listen((bytes) {
    final text = const Utf8Decoder(allowMalformed: true).convert(bytes);
    screen.write(text);
    terminal.write(text);
  });

  final deadline = DateTime.now().add(const Duration(seconds: 60));
  while (DateTime.now().isBefore(deadline)) {
    if (screen.toString().contains(_ready)) break;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  if (!screen.toString().contains(_ready)) {
    if (required) {
      fail('the pane never reached the reader: $screen');
    }
    await subscription.cancel();
    await shutdownProcess(kill: pty.kill, exitCode: pty.exitCode, pid: pty.pid);
    return const _Boundaries([], []);
  }
  // The reader's own greeting is not one of the writes under test.
  sent.clear();

  for (var repeat = 0; repeat < 5; repeat++) {
    for (final key in _keys) {
      terminal.keyInput(key);
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }
  final typed = List<String>.from(sent);
  // Ends the reader, so the log is closed before it is read back.
  terminal.textInput('\x04');
  await Future<void>.delayed(const Duration(milliseconds: 800));
  await subscription.cancel();
  await shutdownProcess(kill: pty.kill, exitCode: pty.exitCode, pid: pty.pid);

  final log = await Process.run(
    'wsl.exe',
    ['-d', distro, '--exec', '/bin/cat', _logPath],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  expect(log.exitCode, 0, reason: 'the reader wrote no log: ${log.stderr}');
  final reads = <String>[];
  for (final line in '${log.stdout}'.split('\n')) {
    final parts = line.trim().split(' ');
    if (parts.length != 2) continue;
    reads.add(parts[1]);
  }
  return _Boundaries(typed, reads);
}

String _toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// The distribution `wsl.exe` opens by default, or null when there is none.
String? _defaultDistro() {
  try {
    final result = Process.runSync('wsl.exe', [
      '-e',
      'sh',
      '-c',
      r'printf %s "$WSL_DISTRO_NAME"',
    ]);
    final name = '${result.stdout}'.trim();
    return name.isEmpty ? null : name;
  } on ProcessException {
    return null;
  }
}

/// Why this suite cannot run here, or null when it can.
String? _probe() {
  if (!Platform.isWindows) return 'A WSL pane is a Windows ConPTY.';
  final distro = _defaultDistro();
  if (distro == null) return 'No WSL distribution answered.';
  final python = Process.runSync('wsl.exe', [
    '-d',
    distro,
    '--exec',
    '/bin/sh',
    '-c',
    'command -v python3',
  ]);
  if (python.exitCode != 0) {
    return 'No python3 in $distro to read raw bytes with.';
  }
  for (final path in [
    r'build\windows\x64\runner\Debug\flutter_pty.dll',
    r'build\windows\x64\runner\Release\flutter_pty.dll',
    r'C:\Program Files\Karmashala\flutter_pty.dll',
  ]) {
    final file = File(path);
    if (!file.existsSync()) continue;
    try {
      DynamicLibrary.open(file.absolute.path);
      return null;
    } on ArgumentError {
      continue;
    }
  }
  return 'No flutter_pty.dll to spawn a ConPTY with; build the app first.';
}
