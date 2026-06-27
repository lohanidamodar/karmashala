import 'dart:convert';
import 'dart:io';

import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart';

import '../domain/terminal_profile.dart';
import 'pty_launch.dart';

/// One open terminal: a stable [id]/[title] and the xterm [Terminal] buffer the
/// UI renders. Implementations own whatever backs the buffer (a real PTY in
/// production, nothing in tests).
abstract class TerminalInstance {
  String get id;
  String get title;
  Terminal get terminal;

  /// Drives selection/scroll for the view — read to copy the current selection.
  TerminalController get controller;

  /// Tears down the backing process/streams.
  void dispose();
}

/// Signature for creating a [TerminalInstance] — injected so tests can supply a
/// process-free fake (a real [Pty] would try to spawn a shell).
typedef TerminalInstanceFactory =
    TerminalInstance Function({
      required String id,
      required TerminalProfile profile,
      String? workingDirectory,
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
    required PtyLaunch launch,
  }) {
    terminal = Terminal(maxLines: 10000);
    // flutter_pty only forwards a tiny allowlist of env vars to the child; pass
    // the full host environment so Windows shells get SystemRoot/WINDIR/etc.
    // (without them powershell.exe/cmd.exe and wsl.exe fail to start).
    final workingDirectory =
        (launch.workingDirectory != null &&
            Directory(launch.workingDirectory!).existsSync())
        ? launch.workingDirectory
        : null;
    _pty = Pty.start(
      launch.executable,
      arguments: launch.arguments,
      environment: Map<String, String>.of(Platform.environment),
      workingDirectory: workingDirectory,
    );

    _pty.output
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(terminal.write);

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
  late final Terminal terminal;
  @override
  final TerminalController controller = TerminalController();

  late final Pty _pty;
  bool _disposed = false;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _pty.kill();
  }
}

/// A [TerminalInstance] that failed to spawn: it renders the error in its buffer
/// so the panel surfaces *why* instead of crashing the app.
class ErrorTerminalInstance implements TerminalInstance {
  ErrorTerminalInstance({
    required this.id,
    required this.title,
    required String message,
  }) {
    terminal = Terminal(maxLines: 1000);
    terminal.write('\x1b[91m$message\x1b[0m\r\n');
  }

  @override
  final String id;
  @override
  final String title;
  @override
  late final Terminal terminal;
  @override
  final TerminalController controller = TerminalController();

  @override
  void dispose() {}
}

/// The production [TerminalInstanceFactory]: builds a [PtyLaunch] for the profile
/// and spawns a [PtyTerminalInstance], degrading to an [ErrorTerminalInstance]
/// (whose buffer shows the failure) if the PTY cannot be created.
TerminalInstance createPtyTerminalInstance({
  required String id,
  required TerminalProfile profile,
  String? workingDirectory,
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
    return PtyTerminalInstance(id: id, title: profile.label, launch: launch);
  } catch (e) {
    final args = launch.arguments.join(' ');
    return ErrorTerminalInstance(
      id: id,
      title: profile.label,
      message:
          'Failed to start "${launch.executable} $args"'
          '${launch.workingDirectory == null ? '' : ' in ${launch.workingDirectory}'}: $e',
    );
  }
}
