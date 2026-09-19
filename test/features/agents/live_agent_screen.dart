import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:xterm2/xterm.dart';

/// A real agent CLI in a real ConPTY, drawn into a real xterm2 [Terminal] —
/// the same emulator a Karmashala pane uses, so [rows] is the grid the status
/// source reads and not a guess at it. For the live tests that measure which
/// keys answer which prompt.
class LiveAgentScreen {
  LiveAgentScreen._(this._pty, this.terminal);

  static LiveAgentScreen start({
    required List<String> argv,
    required String workingDirectory,
    Map<String, String> environment = const {},
    int columns = 160,
    int rows = 50,
  }) {
    final terminal = Terminal(maxLines: 2000)..resize(columns, rows);
    final pty = ConPtyLauncher().start(
      PtySpawnRequest(
        argv: argv,
        workingDirectory: workingDirectory,
        environment: {'TERM': 'xterm-256color', ...environment},
        columns: columns,
        rows: rows,
      ),
    );
    final screen = LiveAgentScreen._(pty, terminal);
    // The emulator answers the terminal's own queries (cursor position,
    // device attributes); a TUI waits for those answers before it draws.
    terminal.onOutput = (data) =>
        pty.write(Uint8List.fromList(utf8.encode(data)));
    screen._output = const Utf8Decoder(
      allowMalformed: true,
    ).bind(pty.output).listen(terminal.write);
    return screen;
  }

  final PtyHandle _pty;
  final Terminal terminal;
  late final StreamSubscription<String> _output;

  /// The visible rows, trailing blanks trimmed.
  List<String> get rows {
    final buffer = terminal.buffer;
    return [
      for (var i = buffer.scrollBack; i < buffer.height; i++)
        buffer.lines[i].getText().trimRight(),
    ];
  }

  String get text => rows.join('\n');

  /// Waits until [test] holds for the visible rows, or throws with the screen.
  Future<void> until(
    bool Function(String screen) test, {
    Duration within = const Duration(seconds: 60),
    String what = 'the expected screen',
  }) async {
    final deadline = DateTime.now().add(within);
    while (!test(text)) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('never saw $what:\n$text');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  Future<void> untilShows(String needle, {Duration? within}) => until(
    (s) => s.contains(needle),
    within: within ?? const Duration(seconds: 60),
    what: '"$needle"',
  );

  /// Writes [keys] one key at a time — an arrow's escape sequence whole — the
  /// way a terminal sends them, pausing [gap] after each.
  Future<void> press(
    String keys, {
    Duration gap = const Duration(milliseconds: 400),
  }) async {
    for (final m in RegExp(r'\x1b\[[A-D]|[\s\S]').allMatches(keys)) {
      _pty.write(Uint8List.fromList(utf8.encode(m[0]!)));
      await Future<void>.delayed(gap);
    }
  }

  /// Writes [keys] now, in one write — what a pane's `textInput` does.
  void send(String keys) => _pty.write(Uint8List.fromList(utf8.encode(keys)));

  /// Writes [bytes] in one write, the way a paste or one `answerPrompt` call
  /// delivers them.
  Future<void> write(String bytes) async {
    _pty.write(Uint8List.fromList(utf8.encode(bytes)));
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }

  Future<int> get exitCode => _pty.exitCode;

  Future<void> close() async {
    await _output.cancel();
    await _pty.close();
  }
}
