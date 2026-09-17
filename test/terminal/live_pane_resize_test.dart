@Tags(['live-wsl'])
library;

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/terminal/data/pane_terminal.dart';
import 'package:karmashala/src/features/terminal/data/terminal_grid_text.dart';
import 'package:karmashala/src/features/terminal/data/terminal_instance.dart';
import 'package:karmashala_terminal_core/profiles.dart';

/// What the process in a pane believes its size is, after the app tells it a
/// new one.
///
/// The report was "resizing doesn't work as expected". Everything above the PTY
/// is measurable in a widget test — `window_resize_test.dart` pins that the
/// grid the terminal is *told* about is exactly the grid it is *drawn* in, at
/// every window size — and a pane's own wiring is one line:
/// `Terminal.onResize` calls `Pty.resize(rows, columns)`. What no widget test
/// can see is whether a resize written into a Windows ConPTY becomes a
/// `TIOCSWINSZ` on the far end, and for a WSL pane the far end is two relays
/// away: the app spawns `cmd.exe /c wsl.exe -d <distro>`, and the process that
/// has to learn the new size is a Linux one inside the distribution.
///
/// So this asks the process itself. `stty size` in the distro and
/// `[Console]::WindowWidth` in PowerShell are the two ends of the same
/// question, and running both is what says whether a failure is the terminal
/// stack or only the WSL wrapper.
///
/// Skips itself where there is no `flutter_pty.dll` to spawn a real ConPTY with
/// — the same shape, and the same reason, as `live_wsl_pane_test.dart`.
void main() {
  // The pane's output coalescer drains on a post-frame callback or a watchdog
  // timer, and asks `SchedulerBinding.instance` for the former: without a
  // binding the very first bytes from the PTY throw before anything is read.
  TestWidgetsFlutterBinding.ensureInitialized();
  final probe = _probe();
  if (probe != null) {
    test('live pane resize test is skipped', () {}, skip: probe);
    return;
  }

  test('a PowerShell pane learns every size the app resizes it to', () async {
    final pane = _Pane(TerminalProfile.powerShell);
    addTearDown(pane.close);
    await pane.settle();

    expect(
      await pane.askPowerShell(),
      _size(80, 25),
      reason: 'flutter_pty starts a ConPTY at its own default',
    );

    // Twice, and asked after each: a handler that sends only the first change
    // and one that stops a size behind both look like "it did resize" if the
    // process is asked once.
    pane.instance.terminal.resize(132, 43);
    // A second resize inside the settle lands late; ask after it has.
    await Future<void>.delayed(kColumnResizeSettle * 2);
    expect(
      await pane.askPowerShell(),
      _size(132, 43),
      reason:
          'Terminal.resize is what a window resize reaches the pane as; if the '
          'process still believes the old grid, nothing above this matters',
    );

    pane.instance.terminal.resize(96, 30);
    // A second resize inside the settle lands late; ask after it has.
    await Future<void>.delayed(kColumnResizeSettle * 2);
    expect(await pane.askPowerShell(), _size(96, 30));
  }, timeout: const Timeout(Duration(seconds: 180)));

  test('a drag\'s worth of resizes leaves the process on the last one', () async {
    final pane = _Pane(TerminalProfile.powerShell);
    addTearDown(pane.close);
    await pane.settle();

    // What dragging a window edge produces: one geometry change per frame, not
    // one at the end. `PaneTerminal` lets the columns settle, so the pane sends
    // the first and the last — and the size the user stopped at is the only one
    // that matters. A relay that dropped the last of a burst would leave the
    // process permanently one size behind, which looks like never sending it.
    for (var i = 0; i < 60; i++) {
      pane.instance.terminal.resize(80 + i, 25 + (i % 20));
      await Future<void>.delayed(const Duration(milliseconds: 8));
    }
    await Future<void>.delayed(kColumnResizeSettle * 2);

    expect(await pane.askPowerShell(), _size(139, 44));
  }, timeout: const Timeout(Duration(seconds: 180)));

  test('a WSL pane learns them through cmd.exe and wsl.exe', () async {
    final distro = _defaultDistro();
    if (distro == null) {
      markTestSkipped('No WSL distribution answered.');
      return;
    }
    final pane = _Pane(
      TerminalProfile(
        id: TerminalProfile.wslId(distro),
        label: '$distro (WSL)',
        shell: TerminalShell.wsl,
        wslDistribution: distro,
      ),
    );
    addTearDown(pane.close);
    await pane.settle();

    expect(await pane.askStty(), _size(80, 25));

    pane.instance.terminal.resize(132, 43);
    // A second resize inside the settle lands late; ask after it has.
    await Future<void>.delayed(kColumnResizeSettle * 2);
    expect(
      await pane.askStty(),
      _size(132, 43),
      reason:
          'the resize has to cross the ConPTY, `cmd.exe /c` and `wsl.exe` and '
          'land as a TIOCSWINSZ on the distro side; a stale size here is a CLI '
          'drawing to a box it no longer has',
    );

    pane.instance.terminal.resize(96, 30);
    // A second resize inside the settle lands late; ask after it has.
    await Future<void>.delayed(kColumnResizeSettle * 2);
    expect(await pane.askStty(), _size(96, 30));
  }, timeout: const Timeout(Duration(seconds: 180)));
}

/// `(columns, rows)` — the order the app thinks in, so both probes report the
/// same shape whatever their own command prints.
({int columns, int rows}) _size(int columns, int rows) => (
  columns: columns,
  rows: rows,
);

/// One throwaway pane, built by the production factory so the wiring under test
/// is the app's own.
class _Pane {
  _Pane(TerminalProfile profile)
    : instance = createPtyTerminalInstance(id: 'live-resize', profile: profile);

  final TerminalInstance instance;

  Future<void> settle() async {
    await _waitFor(RegExp(r'\S'), seconds: 60);
    await Future<void>.delayed(const Duration(seconds: 2));
  }

  /// Asks the process its size and reads the answer back off the screen.
  ///
  /// Every question carries a fresh number, for two reasons: the shell echoes
  /// the command line before it runs it, and the *previous* answer is still on
  /// the screen. Without one, "what do you believe now" is answered by what it
  /// believed a moment ago — which is exactly the failure being looked for, so
  /// it must not be possible to produce it by accident.
  Future<({int columns, int rows})?> _ask(
    String Function(String marker) command,
  ) async {
    final marker = 'SZ${_asked++}';
    final answer = RegExp('$marker:(\\d+)x(\\d+):');
    instance.terminal.textInput('${command(marker)}\r');
    if (!await _waitFor(answer, seconds: 30)) return null;
    final match = answer.firstMatch(_screen())!;
    return (
      columns: int.parse(match.group(1)!),
      rows: int.parse(match.group(2)!),
    );
  }

  int _asked = 0;

  Future<({int columns, int rows})?> askPowerShell() => _ask(
    (marker) =>
        'Write-Host "$marker:\$([Console]::WindowWidth)x'
        '\$([Console]::WindowHeight):"',
  );

  /// `stty size` prints `rows columns`; this turns it round so both probes
  /// answer in the same order.
  Future<({int columns, int rows})?> askStty() => _ask(
    (marker) => r'set -- $(stty size); ' 'echo "$marker:\${2}x\${1}:"',
  );

  String _screen() => terminalTailLines(instance.terminal, lines: 200).join('\n');

  Future<bool> _waitFor(Pattern pattern, {required int seconds}) async {
    final deadline = DateTime.now().add(Duration(seconds: seconds));
    while (DateTime.now().isBefore(deadline)) {
      if (_screen().contains(pattern)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return false;
  }

  Future<void> close() async {
    instance.dispose();
    if (instance is ReapableTerminalInstance) {
      await (instance as ReapableTerminalInstance).reaped;
    }
  }
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

/// Why this suite cannot run here, or null when it can.
///
/// The DLL is loaded **by full path** on purpose — see `live_wsl_pane_test.dart`
/// for why the package's own bare-name open cannot find it under `flutter test`.
String? _probe() {
  if (!Platform.isWindows) return 'A pane here is a Windows ConPTY.';
  const candidates = [
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
