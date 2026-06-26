import 'dart:async';

import '../../../core/process/command_runner.dart';
import '../../../core/process/process_handle.dart';
import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/environment_path.dart';

/// One line of terminal output, tagged by stream.
class TerminalLine {
  const TerminalLine(this.text, {this.isError = false});
  final String text;
  final bool isError;
}

/// Builds the shell launch for an environment.
///
/// A pragmatic, line-oriented console (not a full PTY): `cmd.exe` on Windows,
/// `bash` in WSL. Pure and testable. (A full ANSI/PTY terminal would need a
/// dedicated package and is intentionally out of scope — the terminal is
/// optional.)
CommandRequest shellLaunch(
  EnvironmentKind kind, {
  EnvironmentPath? workingDir,
}) {
  return switch (kind) {
    EnvironmentKind.windowsNative => CommandRequest(
      executable: 'cmd.exe',
      arguments: const ['/Q'],
      workingDirectory: workingDir,
    ),
    EnvironmentKind.wsl => CommandRequest(
      executable: 'bash',
      workingDirectory: workingDir,
    ),
  };
}

/// A live line-oriented shell session over a [ProcessHandle], used by the
/// optional embedded terminal. All process I/O flows through the runner
/// abstraction (constraint 6).
class TerminalSession {
  TerminalSession(Future<ProcessHandle> handle) {
    _attach(handle);
  }

  final StreamController<TerminalLine> _lines =
      StreamController<TerminalLine>();
  final List<String> _pending = [];
  ProcessHandle? _handle;
  bool _stopped = false;

  Stream<TerminalLine> get lines => _lines.stream;

  Future<void> _attach(Future<ProcessHandle> handleFuture) async {
    final ProcessHandle handle;
    try {
      handle = await handleFuture;
    } catch (error) {
      if (!_lines.isClosed) {
        _lines.add(
          TerminalLine('Failed to start shell: $error', isError: true),
        );
        await _lines.close();
      }
      return;
    }
    if (_stopped) {
      await handle.kill();
      return;
    }
    _handle = handle;

    handle.stdoutLines.listen(
      (line) {
        if (!_lines.isClosed) _lines.add(TerminalLine(line));
      },
      onDone: () {
        if (!_lines.isClosed) _lines.close();
      },
    );
    handle.stderrLines.listen((line) {
      if (!_lines.isClosed) _lines.add(TerminalLine(line, isError: true));
    });

    for (final command in _pending) {
      handle.writeLine(command);
    }
    _pending.clear();
  }

  /// Runs [command] (sends it to the shell's stdin).
  void run(String command) {
    final handle = _handle;
    if (handle == null) {
      _pending.add(command);
      return;
    }
    handle.writeLine(command);
  }

  Future<void> stop() async {
    _stopped = true;
    await _handle?.kill();
    if (!_lines.isClosed) await _lines.close();
  }
}
