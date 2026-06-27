import 'dart:convert';

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
    _pty = Pty.start(
      launch.executable,
      arguments: launch.arguments,
      workingDirectory: launch.workingDirectory,
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
      if (!_disposed) _pty.write(const Utf8Encoder().convert(data));
    };
    terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      if (!_disposed) _pty.resize(height, width);
    };
  }

  @override
  final String id;
  @override
  final String title;
  @override
  late final Terminal terminal;

  late final Pty _pty;
  bool _disposed = false;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _pty.kill();
  }
}

/// The production [TerminalInstanceFactory]: builds a [PtyLaunch] for the profile
/// and spawns a [PtyTerminalInstance].
TerminalInstance createPtyTerminalInstance({
  required String id,
  required TerminalProfile profile,
  String? workingDirectory,
}) {
  return PtyTerminalInstance(
    id: id,
    title: profile.label,
    launch: ptyLaunchFor(profile, workingDirectory: workingDirectory),
  );
}
