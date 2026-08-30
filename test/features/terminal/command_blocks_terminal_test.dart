import 'dart:io';

import 'package:chitragupta/src/features/terminal/data/command_block_recorder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// The byte stream a *real* PowerShell 5.1 produced when driven by the script
/// `powerShellIntegrationScript()` generates, captured verbatim.
///
/// This is what makes the round-trip honest: the markers were not hand-written
/// to match the parser, they were recorded from the shell.
String _fixture() => File(
  'test/features/terminal/fixtures/powershell_osc133_session.txt',
).readAsStringSync();

/// A clock that advances one second per reading, so durations are deterministic.
class _TickingClock {
  var _tick = 0;
  DateTime call() => DateTime.utc(2026, 8, 30, 12, 0, _tick++);
}

CommandBlockRecorder _recorderOver(Terminal terminal) =>
    CommandBlockRecorder(terminal, clock: _TickingClock().call)..attach();

void main() {
  test('OSC 133 reaches the app through xterm with no vendored change', () {
    // Proves the transport claim directly: onPrivateOSC is stock xterm 4.0.0.
    final terminal = Terminal(maxLines: 100)..resize(80, 24);
    final seen = <String>[];
    terminal.onPrivateOSC = (code, args) => seen.add('$code:${args.join(",")}');

    terminal.write('\x1b]133;A\x07hi\x1b]133;D;3\x07');

    expect(seen, ['133:A', '133:D,3']);
  });

  test('a BEL-terminated and an ST-terminated marker both arrive', () {
    final terminal = Terminal(maxLines: 100)..resize(80, 24);
    final seen = <String>[];
    terminal.onPrivateOSC = (code, args) => seen.add(args.join(','));

    terminal
      ..write('\x1b]133;A\x07')
      ..write('\x1b]133;B\x1b\\');

    expect(seen, ['A', 'B']);
  });

  group('the recorded PowerShell session', () {
    test('produces one block per command, with the reported exit codes', () {
      final terminal = Terminal(maxLines: 1000)..resize(80, 24);
      final recorder = _recorderOver(terminal);

      terminal.write(_fixture());

      final blocks = recorder.tracker.blocks;
      expect(blocks, hasLength(3));
      expect(blocks.map((b) => b.exitCode), [0, 7, 7]);
      expect(blocks.map((b) => b.failed), [false, true, true]);
      expect(
        blocks.every((b) => b.isRunning == false),
        isTrue,
        reason: 'every command in the fixture finished',
      );
    });

    test('recovers each command from the text between B and C', () {
      final terminal = Terminal(maxLines: 1000)..resize(80, 24);
      final recorder = _recorderOver(terminal);

      terminal.write(_fixture());

      expect(recorder.tracker.blocks.map((b) => b.command), [
        'cmd /c exit 0',
        'cmd /c exit 7',
        'Get-Item nope',
      ]);
    });

    test('records a duration for every completed command', () {
      final terminal = Terminal(maxLines: 1000)..resize(80, 24);
      final recorder = _recorderOver(terminal);

      terminal.write(_fixture());

      for (final block in recorder.tracker.blocks) {
        expect(block.duration, isNotNull);
        expect(block.duration!.inMicroseconds, greaterThanOrEqualTo(0));
      }
    });

    test('the prompt line of each block points at that command prompt', () {
      final terminal = Terminal(maxLines: 1000)..resize(80, 24);
      final recorder = _recorderOver(terminal);

      terminal.write(_fixture());

      final lines = recorder.tracker.blocks.map((b) => b.promptLine).toList();
      expect(lines.every((l) => l != null), isTrue);
      expect(
        lines,
        orderedEquals([...lines]..sort()),
        reason: 'blocks are ordered down the buffer',
      );
      for (final block in recorder.tracker.blocks) {
        expect(
          terminal.buffer.lines[block.promptLine!].getText(),
          contains('C:\\ws>'),
          reason: 'the jump target is the line the prompt was drawn on',
        );
      }
    });

    test('the same stream split across chunks gives the same blocks', () {
      // The PTY delivers 1 KB at a time, so a marker can straddle two writes.
      // Seven bytes is small enough to split every marker in the fixture.
      final whole = Terminal(maxLines: 1000)..resize(80, 24);
      final wholeRecorder = _recorderOver(whole);
      whole.write(_fixture());

      final chunked = Terminal(maxLines: 1000)..resize(80, 24);
      final chunkedRecorder = _recorderOver(chunked);
      final text = _fixture();
      for (var i = 0; i < text.length; i += 7) {
        chunked.write(text.substring(i, (i + 7).clamp(0, text.length)));
      }

      expect(
        chunkedRecorder.tracker.blocks.map((b) => b.exitCode),
        wholeRecorder.tracker.blocks.map((b) => b.exitCode),
      );
      expect(
        chunkedRecorder.tracker.blocks.map((b) => b.command),
        wholeRecorder.tracker.blocks.map((b) => b.command),
      );
    });

    test('no marker leaks into the rendered text', () {
      final terminal = Terminal(maxLines: 1000)..resize(80, 24);
      _recorderOver(terminal);

      terminal.write(_fixture());

      final rendered = [
        for (var i = 0; i < 12; i++) terminal.buffer.lines[i].getText(),
      ].join('\n');
      expect(rendered, isNot(contains('133')));
      expect(rendered, isNot(contains('\x1b')));
      expect(rendered, contains('C:\\ws>'));
    });
  });

  group('a shell with no integration', () {
    test('produces no blocks at all', () {
      // The silent-degrade requirement: an un-integrated shell must look
      // exactly as it does today.
      final terminal = Terminal(maxLines: 1000)..resize(80, 24);
      final recorder = _recorderOver(terminal);

      terminal.write('PS C:\\> dir\r\nfoo.txt\r\nPS C:\\> ');

      expect(recorder.tracker.blocks, isEmpty);
      expect(recorder.tracker.pending, isNull);
    });

    test('an unrelated OSC does not create a block', () {
      final terminal = Terminal(maxLines: 1000)..resize(80, 24);
      final recorder = _recorderOver(terminal);

      // OSC 7 (cwd) and OSC 0 (title) are both routine shell output.
      terminal.write('\x1b]7;file:///C:/ws\x07\x1b]0;a title\x07hello');

      expect(recorder.tracker.blocks, isEmpty);
      expect(recorder.tracker.pending, isNull);
    });
  });

  test('a block dies with the line it points at', () {
    // maxLines is tiny so the first command scrolls out of history; a stale
    // integer line number would silently point somewhere wrong.
    final terminal = Terminal(maxLines: 40)..resize(20, 10);
    final recorder = _recorderOver(terminal);

    terminal.write('\x1b]133;A\x07> \x1b]133;C\x07x\r\n\x1b]133;D;0\x07');
    expect(recorder.tracker.blocks, hasLength(1));

    for (var i = 0; i < 80; i++) {
      terminal.write('filler $i\r\n');
    }
    recorder.tracker.pruneEvicted();

    expect(recorder.tracker.blocks, isEmpty);
  });
}
