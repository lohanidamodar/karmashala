@Tags(['live-wsl'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_pty/flutter_pty.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/terminal/data/process_shutdown.dart';
import 'package:karmashala/src/features/terminal/data/pty_launch.dart';
import 'package:karmashala_terminal_core/profiles.dart';

/// What a WSL pane does with `Ctrl+C`, and what closing it leaves behind.
///
/// Neither had been checked since the launch path moved to `cmd.exe /c` (the
/// `binfmt_misc` / `MZ: command not found` fix), and both questions are about a
/// boundary no unit test can see: the app writes `0x03` into a **Windows**
/// ConPTY, and the process that has to notice it is a **Linux** one, three
/// relays away — `cmd.exe` → `wsl.exe` → the distro's pty. Whether the wrapper
/// swallows the byte, and whether a `taskkill /T` on the Windows side reaches
/// across into the distribution, are facts about that chain and nothing else.
///
/// Measured on Windows 10.0.26200 against `archlinux`: the byte arrives (the
/// foreground process dies, the pane's shell does not) and the tree is reaped
/// (the distro-side child is gone once the app's own [shutdownProcess] returns).
/// This file is what keeps both true.
///
/// Skips itself where there is no WSL or no `flutter_pty.dll` to spawn a real
/// ConPTY with — the same shape as `live_wsl_hook_test.dart`.
void main() {
  final probe = _probe();
  if (probe != null) {
    test('live WSL pane test is skipped', () {}, skip: probe);
    return;
  }
  final distro = _defaultDistro()!;
  final profile = TerminalProfile(
    id: TerminalProfile.wslId(distro),
    label: '$distro (WSL)',
    shell: TerminalShell.wsl,
    wslDistribution: distro,
  );

  test('Ctrl+C reaches the process inside a WSL pane', () async {
    final pane = await _WslPane.open(profile);
    addTearDown(pane.close);

    // A foreground process that will not end on its own, whose pid the pane
    // prints — `exec` so the pid named is the one actually in the foreground.
    final pid = await pane.startMarkedChild('KPID');
    expect(await _aliveIn(distro, pid), isTrue);

    pane.send('\x03');
    await Future<void>.delayed(const Duration(seconds: 2));

    expect(
      await _aliveIn(distro, pid),
      isFalse,
      reason:
          'the 0x03 has to cross cmd.exe and wsl.exe and become a SIGINT on '
          'the distro side; if the wrapper swallowed it, this process would '
          'still be running',
    );
    expect(
      pane.exited,
      isFalse,
      reason:
          'and it must interrupt the child, not take the pane with it — '
          '`cmd /c` terminating on a CTRL_C_EVENT would close the tab',
    );
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('closing a WSL pane reaps the process tree inside the distro', () async {
    final pane = await _WslPane.open(profile);
    // Also on the failure path: a run that proves the tree is *not* reaped must
    // not be the thing that leaves a process behind.
    addTearDown(pane.close);
    final pid = await pane.startMarkedChild('KPID');
    expect(await _aliveIn(distro, pid), isTrue);

    // The app's own teardown, not a `taskkill` written out here: what is under
    // test is what `TerminalInstance.dispose` does.
    await shutdownProcess(
      kill: pane.pty.kill,
      exitCode: pane.pty.exitCode,
      pid: pane.pty.pid,
    );
    await Future<void>.delayed(const Duration(seconds: 3));

    expect(
      await _aliveIn(distro, pid),
      isFalse,
      reason:
          'killing the Windows tree has to hang up the relay; a survivor here '
          'is a process holding a pty with nothing on the other end of it',
    );
    // Whatever the assertion said, leave nothing running in the distro.
    await _killIn(distro, pid);
  }, timeout: const Timeout(Duration(seconds: 90)));
}

/// One throwaway pane: the launch this app really builds, in a real ConPTY.
class _WslPane {
  _WslPane(this.pty) {
    unawaited(pty.exitCode.then((_) => exited = true));
    pty.output.listen(
      (bytes) => _buffer.write(
        const Utf8Decoder(allowMalformed: true).convert(bytes),
      ),
    );
  }

  static Future<_WslPane> open(TerminalProfile profile) async {
    final launch = ptyLaunchFor(profile);
    expect(
      launch.executable,
      'cmd.exe',
      reason: 'the wrapper is the thing under test; see pty_launch.dart',
    );
    final pane = _WslPane(
      Pty.start(
        launch.executable,
        arguments: launch.arguments,
        environment: {...Platform.environment, ...launch.environment},
        rows: 30,
        columns: 100,
      ),
    );
    // A login shell has a profile to read before it will echo anything back.
    await pane.settle();
    return pane;
  }

  final Pty pty;
  bool exited = false;
  final StringBuffer _buffer = StringBuffer();

  void send(String text) =>
      pty.write(Uint8List.fromList(const Utf8Encoder().convert(text)));

  Future<void> settle() async {
    await _waitFor(RegExp(r'\S'), seconds: 30);
    await Future<void>.delayed(const Duration(seconds: 2));
  }

  /// Runs a process in the pane that prints its own pid and then blocks, and
  /// returns that pid.
  Future<String> startMarkedChild(String marker) async {
    _buffer.clear();
    send("sh -c 'echo $marker:\$\$; exec sleep 600'\r");
    final found = await _waitFor(RegExp('$marker:(\\d+)'), seconds: 20);
    expect(found, isTrue, reason: 'the pane never ran the command: $_buffer');
    return RegExp('$marker:(\\d+)').firstMatch(_buffer.toString())!.group(1)!;
  }

  Future<bool> _waitFor(Pattern pattern, {required int seconds}) async {
    final deadline = DateTime.now().add(Duration(seconds: seconds));
    while (DateTime.now().isBefore(deadline)) {
      if (_buffer.toString().contains(pattern)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return false;
  }

  Future<void> close() async {
    if (exited) return;
    await shutdownProcess(
      kill: pty.kill,
      exitCode: pty.exitCode,
      pid: pty.pid,
    );
  }
}

Future<bool> _aliveIn(String distro, String pid) async {
  final result = await Process.run('wsl.exe', [
    '-d',
    distro,
    '-e',
    'sh',
    '-c',
    'kill -0 $pid 2>/dev/null && echo ALIVE || echo GONE',
  ]);
  return '${result.stdout}'.contains('ALIVE');
}

Future<void> _killIn(String distro, String pid) => Process.run('wsl.exe', [
  '-d',
  distro,
  '-e',
  'sh',
  '-c',
  'kill -9 $pid 2>/dev/null; true',
]);

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
///
/// The DLL is loaded **by full path** on purpose: `flutter_pty` asks for the
/// bare name, which under `flutter test` is searched for beside `flutter_tester`
/// and in the working directory — neither of which has it without a build.
/// Windows keys loaded modules by name, so pre-loading the same file from where
/// it actually lives makes the package's own `DynamicLibrary.open` find it.
String? _probe() {
  if (!Platform.isWindows) return 'A WSL pane is a Windows ConPTY.';
  if (_defaultDistro() == null) return 'No WSL distribution answered.';
  final candidates = [
    r'build\windows\x64\runner\Debug\flutter_pty.dll',
    r'build\windows\x64\runner\Release\flutter_pty.dll',
    r'C:\Program Files\Karmashala\flutter_pty.dll',
  ];
  for (final path in candidates) {
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
