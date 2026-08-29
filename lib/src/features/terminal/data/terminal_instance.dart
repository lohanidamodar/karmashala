import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart';

import '../domain/terminal_profile.dart';
import 'pty_launch.dart';
import 'pty_output_coalescer.dart';

/// One open terminal: a stable [id]/[title] and the xterm [Terminal] buffer the
/// UI renders. Implementations own whatever backs the buffer (a real PTY in
/// production, nothing in tests).
abstract class TerminalInstance {
  String get id;
  String get title;
  Terminal get terminal;

  /// The [TerminalProfile] id this pane was launched from, and the directory it
  /// started in — kept so the pane can be recreated after a restart.
  String get profileId;
  String? get workingDirectory;

  /// Drives selection/scroll for the view — read to copy the current selection.
  TerminalController get controller;

  /// Owned by the instance rather than the widget so the app can focus a pane
  /// and scroll it to a search hit without reaching into the widget tree.
  FocusNode get focusNode;
  ScrollController get scrollController;

  /// Tears down the backing process/streams. Safe to call more than once.
  void dispose();
}

/// Signature for creating a [TerminalInstance] — injected so tests can supply a
/// process-free fake (a real [Pty] would try to spawn a shell).
typedef TerminalInstanceFactory =
    TerminalInstance Function({
      required String id,
      required TerminalProfile profile,
      String? workingDirectory,
      String? restoredScrollback,
    });

/// A [TerminalInstance] backed by a real host ConPTY ([Pty]) wired to an xterm
/// [Terminal]: PTY output is decoded into the buffer, keystrokes are encoded
/// back to the PTY, and terminal resizes are forwarded.
///
/// This is the one deliberate exception to the `CommandRunner` rule
/// (architecture constraint 6): an interactive terminal needs a pseudo-terminal,
/// which the run-to-completion/stream abstraction does not model.
class PtyTerminalInstance implements TerminalInstance {
  PtyTerminalInstance({
    required this.id,
    required this.title,
    required this.profileId,
    required PtyLaunch launch,
    this.workingDirectory,
    String? restoredScrollback,
  }) {
    terminal = Terminal(maxLines: 10000);
    // Replay the previous session's scrollback *before* the shell starts, so
    // restored history sits above the new process's first output.
    writeRestoredScrollback(terminal, restoredScrollback);
    // flutter_pty only forwards a tiny allowlist of env vars to the child; pass
    // the host environment so Windows shells get SystemRoot/WINDIR/etc. (without
    // them powershell.exe/cmd.exe and wsl.exe fail to start) — sanitized so a
    // POSIX env leaked from launching via WSL doesn't break wsl.exe.
    final workingDirectory =
        (launch.workingDirectory != null &&
            Directory(launch.workingDirectory!).existsSync())
        ? launch.workingDirectory
        : null;
    _pty = Pty.start(
      launch.executable,
      arguments: launch.arguments,
      environment: _ptyEnvironment(),
      workingDirectory: workingDirectory,
    );

    // Buffer the raw PTY bytes and hand them to the terminal once per frame.
    // flutter_pty reads 1 KB at a time, so without this a busy shell costs
    // hundreds of decodes, parses and notifyListeners() a second on the UI
    // isolate — which is what the streaming stutter was.
    _coalescer = PtyOutputCoalescer(onData: terminal.write);
    _outputSubscription = _pty.output.listen(_coalescer.add);

    _pty.exitCode.then((code) {
      if (!_disposed) {
        terminal.write(
          '\r\n\x1b[90m[process exited with code $code]\x1b[0m\r\n',
        );
      }
    });

    terminal.onOutput = (data) {
      if (_disposed) return;
      try {
        _pty.write(const Utf8Encoder().convert(data));
      } catch (_) {
        // The PTY has gone away — ignore late keystrokes.
      }
    };
    terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      if (_disposed) return;
      try {
        _pty.resize(height, width);
      } catch (_) {}
    };
  }

  @override
  final String id;
  @override
  final String title;
  @override
  final String profileId;
  @override
  final String? workingDirectory;
  @override
  late final Terminal terminal;
  @override
  final TerminalController controller = TerminalController();
  @override
  final FocusNode focusNode = FocusNode();
  @override
  final ScrollController scrollController = ScrollController();

  late final Pty _pty;
  late final PtyOutputCoalescer _coalescer;
  late final StreamSubscription<Uint8List> _outputSubscription;
  bool _disposed = false;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_outputSubscription.cancel());
    _coalescer.dispose();
    focusNode.dispose();
    scrollController.dispose();
    _pty.kill();
  }
}

/// Writes [scrollback] into [terminal] followed by a dim marker, so the user can
/// see where replayed history ends and the live process begins.
///
/// Does nothing when there is nothing to restore.
void writeRestoredScrollback(Terminal terminal, String? scrollback) {
  if (scrollback == null || scrollback.isEmpty) return;
  final at = DateTime.now();
  final stamp =
      '${at.year}-${_two(at.month)}-${_two(at.day)} '
      '${_two(at.hour)}:${_two(at.minute)}';
  terminal
    ..write(scrollback)
    ..write('\r\n\x1b[90m\u2500\u2500 restored \u2500 $stamp '
        '\u2500\u2500\x1b[0m\r\n');
}

String _two(int value) => value.toString().padLeft(2, '0');

/// Builds the environment for a Windows PTY child.
///
/// Normally this is just the host environment. But when the app is launched from
/// a WSL/Unix shell (e.g. `flutter run -d windows` from fish), a POSIX `PATH`
/// (`/usr/bin:/bin:…`), `SHELL=/usr/bin/fish` and `WSL*` interop vars leak into
/// the Windows process. Handing those to `wsl.exe`/`powershell.exe` breaks them,
/// so we rebuild a clean Windows `Path` and drop the Unix leak.
Map<String, String> _ptyEnvironment() {
  final env = Map<String, String>.of(Platform.environment);

  // WSL-interop / Unix-shell leaks (present only when launched from WSL); these
  // confuse wsl.exe and the Windows shells. Harmless no-ops on a clean launch.
  final shell = env['SHELL'];
  if (shell != null && shell.startsWith('/')) env.remove('SHELL');
  env
    ..remove('WSLENV')
    ..remove('WSL_INTEROP')
    ..remove('WSL_DISTRO_NAME');

  // A POSIX PATH means we were launched from a Unix shell — rebuild a Windows
  // PATH so wsl.exe / powershell.exe / cmd.exe resolve.
  final path = env['Path'] ?? env['PATH'];
  if (path != null && path.startsWith('/')) {
    final sysRoot = env['SystemRoot'] ?? env['windir'] ?? r'C:\Windows';
    env
      ..remove('PATH')
      ..['Path'] =
          '$sysRoot\\System32;$sysRoot;'
          '$sysRoot\\System32\\WindowsPowerShell\\v1.0;'
          '$sysRoot\\System32\\wbem';
  }
  return env;
}

/// A [TerminalInstance] that failed to spawn: it renders the error in its buffer
/// so the panel surfaces *why* instead of crashing the app.
class ErrorTerminalInstance implements TerminalInstance {
  ErrorTerminalInstance({
    required this.id,
    required this.title,
    required this.profileId,
    required String message,
    this.workingDirectory,
    String? restoredScrollback,
  }) {
    terminal = Terminal(maxLines: 1000);
    writeRestoredScrollback(terminal, restoredScrollback);
    terminal.write('\x1b[91m$message\x1b[0m\r\n');
  }

  @override
  final String id;
  @override
  final String title;
  @override
  final String profileId;
  @override
  final String? workingDirectory;
  @override
  late final Terminal terminal;
  @override
  final TerminalController controller = TerminalController();
  @override
  final FocusNode focusNode = FocusNode();
  @override
  final ScrollController scrollController = ScrollController();

  bool _disposed = false;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    focusNode.dispose();
    scrollController.dispose();
  }
}

/// The production [TerminalInstanceFactory]: builds a [PtyLaunch] for the profile
/// and spawns a [PtyTerminalInstance], degrading to an [ErrorTerminalInstance]
/// (whose buffer shows the failure) if the PTY cannot be created.
TerminalInstance createPtyTerminalInstance({
  required String id,
  required TerminalProfile profile,
  String? workingDirectory,
  String? restoredScrollback,
}) {
  // The terminal profiles (PowerShell/cmd/WSL) assume a Windows host. When the
  // app itself runs on Linux/macOS (e.g. inside WSL), `wsl.exe`/`powershell.exe`
  // don't exist — we're already in the target shell — so just open the login
  // shell in the working directory.
  final PtyLaunch launch;
  if (Platform.isWindows) {
    launch = ptyLaunchFor(profile, workingDirectory: workingDirectory);
  } else {
    final shell = Platform.environment['SHELL'] ?? '/bin/bash';
    launch = PtyLaunch(executable: shell, workingDirectory: workingDirectory);
  }
  try {
    return PtyTerminalInstance(
      id: id,
      title: profile.label,
      profileId: profile.id,
      launch: launch,
      workingDirectory: workingDirectory,
      restoredScrollback: restoredScrollback,
    );
  } catch (e) {
    final args = launch.arguments.join(' ');
    return ErrorTerminalInstance(
      id: id,
      title: profile.label,
      profileId: profile.id,
      workingDirectory: workingDirectory,
      restoredScrollback: restoredScrollback,
      message:
          'Failed to start "${launch.executable} $args"'
          '${launch.workingDirectory == null ? '' : ' in ${launch.workingDirectory}'}: $e',
    );
  }
}
