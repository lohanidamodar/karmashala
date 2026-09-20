import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_terminal_runtime/instances.dart';
import 'package:karmashala_terminal_runtime/screen_reading.dart';
import 'package:karmashala_terminal_runtime/scrollback.dart';
import 'package:xterm2/xterm.dart';

/// What a replay must never do: answer.
///
/// Retained history can hold the DSR/DA queries a shell or agent emitted. The
/// emulator answers them as it parses, and on a restore that answer goes to the
/// **live** process — the user finds `^[[?1;2c` typed at their prompt. Every
/// pane class happens to assign `terminal.onOutput` after replaying, so these
/// tests attach it *first*: that is the reordering the guard exists for, and
/// the reason the ordering must not be the only thing holding.

/// Sequences this emulator replies to: primary DA, secondary DA,
/// operating-status DSR and cursor-position DSR.
const _queries = '\x1b[c\x1b[>c\x1b[5n\x1b[6n';

void main() {
  late Terminal terminal;
  late List<String> toProcess;

  setUp(() {
    toProcess = <String>[];
    terminal = Terminal()..onOutput = toProcess.add;
    // The sink is live and these really are queries, or nothing below proves
    // anything.
    terminal.write(_queries);
    expect(toProcess, isNotEmpty);
    toProcess.clear();
  });

  test('replaying a device query writes nothing to the process', () {
    replayScrollback(terminal, 'a log line\r\n$_queries\r\nanother\r\n');

    expect(toProcess, isEmpty);
  });

  test('restoring a pane writes nothing to the process', () {
    writeRestoredScrollback(terminal, 'earlier output\r\n$_queries');

    expect(toProcess, isEmpty);
    // The history still landed: the guard silences the replies, not the replay.
    expect(terminalTailLines(terminal), contains('earlier output'));
  });

  test('unparking a pane writes nothing to the process', () {
    terminal.write('scrolled away\r\n$_queries\r\n');
    toProcess.clear();
    ScrollbackPark(terminal)
      ..park()
      ..unpark();

    expect(toProcess, isEmpty);
  });

  test('the process gets its answers again once the replay is over', () {
    replayScrollback(terminal, _queries);
    terminal.write(_queries);

    expect(
      toProcess,
      isNotEmpty,
      reason: 'the sink is borrowed for the replay, not taken',
    );
  });

  test('a replay that throws part-way still gives the sink back', () {
    // A callback the parser reaches mid-write is the shape of failure the
    // restore has to survive; BEL is the cheapest one to provoke.
    terminal.onBell = () => throw StateError('boom');

    expect(
      () => replayScrollback(terminal, 'before\x07after'),
      throwsA(isA<StateError>()),
    );

    terminal.onBell = null;
    terminal.write(_queries);
    expect(toProcess, isNotEmpty);
  });
}
