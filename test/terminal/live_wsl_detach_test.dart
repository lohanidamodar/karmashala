@Tags(['live-wsl'])
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_pty/flutter_pty.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/terminal/data/process_shutdown.dart';
import 'package:karmashala/src/features/terminal/data/pty_launch.dart';
import 'package:karmashala/src/features/terminal/data/terminal_grid_text.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:xterm2/xterm.dart';

/// Whether closing an **empty** WSL shell ends it, against a real prompt.
///
/// `shouldDetachOnClose` guesses whether a shell has history worth keeping by
/// counting non-blank lines, and the whole difficulty is that a prompt is not
/// history. No unit test can see that: it turns on how many rows a real shell
/// paints per command, which is a property of the user's prompt and of nothing
/// this repository controls. A WSL pane is where it matters most, because
/// shell integration is off by default — so a WSL pane usually is not
/// instrumented, and the line count is the only rule it ever gets.
///
/// The owner's report was *"empty wsl terminal stays in the background instead
/// of just ending"*. Measured on Windows 10.0.26200 against `archlinux`, whose
/// zsh runs starship at three rows per command:
///
/// ```txt
/// idle, untouched          nonBlank=2     released
/// after 1 silent command   nonBlank=5     released
/// after 2 silent commands  nonBlank=8     PARKED   <- the bug
/// after `pwd`              nonBlank=12    parked
/// after `ls`               nonBlank=106   parked
/// ```
///
/// The assertions below are deliberately about **relationships** rather than
/// those numbers, so a machine with a one-line prompt proves the same rule.
///
/// Skips itself where there is no WSL or no `flutter_pty.dll` to spawn a real
/// ConPTY with — the same shape as `live_wsl_pane_test.dart`.
void main() {
  final probe = _probe();
  if (probe != null) {
    test('live WSL detach test is skipped', () {}, skip: probe);
    return;
  }
  final distro = _defaultDistro()!;
  final profile = TerminalProfile(
    id: TerminalProfile.wslId(distro),
    label: '$distro (WSL)',
    shell: TerminalShell.wsl,
    wslDistribution: distro,
  );

  test(
    'a shell that printed nothing is released; one that printed is kept',
    () async {
      final pane = await _WslPane.open(profile);
      addTearDown(pane.close);

      expect(
        pane.greetingLines,
        isNull,
        reason:
            'nothing has been submitted, so there is no greeting yet — and '
            'the terminal\'s own ESC[I focus report must not have set one',
      );
      expect(
        pane.parked,
        isFalse,
        reason:
            'an untouched shell is not something anyone would come back for',
      );

      // Two commands that print absolutely nothing. Every line they add to the
      // buffer is the shell redrawing its prompt.
      await pane.run('true');
      await pane.run('true');

      expect(
        pane.greetingLines,
        isNotNull,
        reason: 'submitting a line is what records the greeting',
      );
      expect(
        pane.greetingLines,
        greaterThan(0),
        reason: 'the shell had painted a prompt before anything was typed',
      );
      expect(
        pane.parked,
        isFalse,
        reason:
            'this is the report: two commands that printed nothing must not '
            'park a shell in the background list. nonBlank=${pane.nonBlankLines} '
            'greeting=${pane.greetingLines}',
      );

      // Now something that really does print.
      await pane.run('ls -a /usr/bin');

      expect(
        pane.parked,
        isTrue,
        reason:
            'a shell with real output in it is still worth keeping. '
            'nonBlank=${pane.nonBlankLines} greeting=${pane.greetingLines}',
      );
    },
    timeout: const Timeout(Duration(seconds: 180)),
  );
}

/// One throwaway pane: the launch this app really builds, in a real ConPTY,
/// with the greeting recorded exactly the way `PtyTerminalInstance` records it.
class _WslPane {
  _WslPane(this.pty) {
    pty.output.listen(
      (bytes) => terminal.write(
        const Utf8Decoder(allowMalformed: true).convert(bytes),
      ),
    );
  }

  static Future<_WslPane> open(TerminalProfile profile) async {
    final launch = ptyLaunchFor(profile);
    final pane = _WslPane(
      Pty.start(
        launch.executable,
        arguments: launch.arguments,
        environment: {...Platform.environment, ...launch.environment},
        rows: 30,
        columns: 100,
      ),
    );
    // A login shell has a profile to read before it paints anything.
    await pane._settle();
    return pane;
  }

  final Pty pty;
  final Terminal terminal = Terminal(maxLines: 10000);
  int? greetingLines;

  int get nonBlankLines => nonBlankLineCount(terminal);

  /// The rule under test, asked the way the controller asks it for an
  /// un-instrumented shell that is still running.
  bool get parked => shouldDetachOnClose(
    isLive: true,
    isAgentSession: false,
    commandRunning: null,
    nonBlankLines: nonBlankLines,
    greetingLines: greetingLines,
  );

  /// Types [command] and waits for it to finish — the same two steps
  /// `PtyTerminalInstance.onOutput` takes, in the same order, so the greeting
  /// is captured before the submitted bytes are echoed back.
  Future<void> run(String command) async {
    final data = '$command\r';
    if (greetingLines == null && data.contains('\r')) {
      greetingLines = nonBlankLineCount(terminal);
    }
    pty.write(Uint8List.fromList(const Utf8Encoder().convert(data)));
    await _settle();
  }

  /// Waits until the shell stops painting.
  ///
  /// Quiescence rather than a fixed delay, and that is not just tidiness: a
  /// login shell paints its prompt in more than one go, and typing into a
  /// half-drawn one makes it draw another — which lands in the buffer as an
  /// extra prompt cycle and reads exactly like history. A person cannot type
  /// before the prompt they are waiting for appears, so the test must not
  /// either.
  Future<void> _settle() async {
    const quiet = Duration(milliseconds: 1500);
    const tick = Duration(milliseconds: 250);
    final deadline = DateTime.now().add(const Duration(seconds: 40));
    var last = -1;
    var since = DateTime.now();
    while (DateTime.now().isBefore(deadline)) {
      final now = nonBlankLines;
      if (now != last) {
        last = now;
        since = DateTime.now();
      } else if (now > 0 && DateTime.now().difference(since) >= quiet) {
        return;
      }
      await Future<void>.delayed(tick);
    }
  }

  Future<void> close() =>
      shutdownProcess(kill: pty.kill, exitCode: pty.exitCode, pid: pty.pid);
}

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

/// Why this suite cannot run here, or null when it can. See
/// `live_wsl_pane_test.dart` for why the DLL is loaded by full path.
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
