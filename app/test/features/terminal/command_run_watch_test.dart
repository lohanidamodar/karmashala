import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_terminal_runtime/screen_reading.dart';
import 'package:karmashala_terminal_core/shell_integration.dart';
import 'package:xterm2/xterm.dart';

/// The byte stream a *real* PowerShell 5.1 produced under
/// `powerShellIntegrationScript()`, captured verbatim — the same fixture
/// `command_blocks_terminal_test.dart` reads.
///
/// Scoping output to one command is a claim about where the markers land in the
/// buffer, so it is worth making against bytes a shell actually emitted rather
/// than against a hand-written stream shaped to agree with the reader.
String _fixture() => File(
  'test/features/terminal/fixtures/powershell_osc133_session.txt',
).readAsStringSync();

Terminal _terminal({int maxLines = 1000}) =>
    Terminal(maxLines: maxLines)..resize(80, 24);

/// The router that owns a terminal's single OSC slot — what a pane installs, so
/// the recorder registers with it rather than taking the slot itself.
OscRouter _routerFor(Terminal terminal) {
  final router = OscRouter();
  terminal.onPrivateOSC = router.dispatch;
  return router;
}

void main() {
  group('reading one command\'s output out of the buffer', () {
    test('the recorded PowerShell session gives each command its own', () {
      final terminal = _terminal();
      final recorder = CommandBlockRecorder(terminal)
        ..attach(_routerFor(terminal));

      terminal.write(_fixture());

      final blocks = recorder.tracker.blocks;
      expect(blocks, hasLength(3));
      // `cmd /c exit 0` and `cmd /c exit 7` print nothing, and the prompt line
      // above them is not theirs.
      expect(readCommandOutput(terminal, blocks[0]).lines, isEmpty);
      expect(readCommandOutput(terminal, blocks[1]).lines, isEmpty);
      expect(readCommandOutput(terminal, blocks[2]).lines, [
        'Get-Item : Cannot find path.',
      ]);
    });

    test('the prompt drawn after the command is not part of it', () {
      // The `D` marker anchors to the line the *next* prompt is about to be
      // drawn on, so a reader that took whole lines would hand back the prompt
      // — and, once the user typed again, their next command as well.
      final terminal = _terminal();
      final recorder = CommandBlockRecorder(terminal)
        ..attach(_routerFor(terminal));

      terminal
        ..write('\x1b]133;A\x07PS C:\\ws> \x1b]133;B\x07echo hi\r\n')
        ..write('\x1b]133;C\x07hi\r\n')
        // D and the next A arrive together, then the prompt is drawn — the
        // order the injected PowerShell script really emits them in.
        ..write(
          '\x1b]133;D;0\x07\x1b]133;A\x07PS C:\\ws> \x1b]133;B\x07rm -rf /',
        );

      expect(
        readCommandOutput(terminal, recorder.tracker.blocks.single).lines,
        ['hi'],
      );
    });

    test('a command still running is read up to the end of the buffer', () {
      final terminal = _terminal();
      final recorder = CommandBlockRecorder(terminal)
        ..attach(_routerFor(terminal));

      terminal
        ..write('\x1b]133;A\x07> \x1b]133;B\x07npm run dev\r\n')
        ..write('\x1b]133;C\x07listening on 3000\r\nready\r\n');

      final running = recorder.tracker.pending!;
      expect(running.isRunning, isTrue);
      expect(readCommandOutput(terminal, running).lines, [
        'listening on 3000',
        'ready',
      ]);
    });

    test('a cap keeps the tail and says how many lines it dropped', () {
      final terminal = _terminal();
      final recorder = CommandBlockRecorder(terminal)
        ..attach(_routerFor(terminal));

      terminal.write('\x1b]133;A\x07> \x1b]133;B\x07seq\r\n\x1b]133;C\x07');
      for (var i = 0; i < 20; i++) {
        terminal.write('line $i\r\n');
      }
      terminal.write('\x1b]133;D;0\x07');

      final read = readCommandOutput(
        terminal,
        recorder.tracker.blocks.single,
        maxLines: 5,
      );

      // The tail, because that is where a build puts the thing that broke.
      expect(read.lines, [
        'line 15',
        'line 16',
        'line 17',
        'line 18',
        'line 19',
      ]);
      expect(read.omitted, 15);
      expect(read.scoped, isTrue);
    });

    test('output that scrolled out of history is not passed off as scoped', () {
      final terminal = _terminal(maxLines: 30);
      final recorder = CommandBlockRecorder(terminal)
        ..attach(_routerFor(terminal));

      terminal.write('\x1b]133;A\x07> \x1b]133;B\x07seq\r\n\x1b]133;C\x07');
      for (var i = 0; i < 200; i++) {
        terminal.write('line $i\r\n');
      }
      terminal.write('\x1b]133;D;0\x07');

      final read = readCommandOutput(terminal, recorder.tracker.blocks.single);

      expect(read.scoped, isFalse);
      expect(read.lines, isEmpty);
    });
  });

  group('completion listeners', () {
    test('fire once per completed block, in order', () {
      final terminal = _terminal();
      final recorder = CommandBlockRecorder(terminal)
        ..attach(_routerFor(terminal));
      final ended = <int?>[];
      recorder.tracker.addCompletionListener(
        (block) => ended.add(block.exitCode),
      );

      terminal.write(_fixture());

      expect(ended, [0, 7, 7]);
    });

    test(
      'a listener that removes itself stops hearing, and the rest do not',
      () {
        final terminal = _terminal();
        final recorder = CommandBlockRecorder(terminal)
          ..attach(_routerFor(terminal));
        final first = <int?>[];
        final all = <int?>[];
        late final void Function(CommandBlock) once;
        once = (block) {
          first.add(block.exitCode);
          // Removing during the notification is exactly what a satisfied
          // `terminal_run` does, so iterating the live list would skip the next
          // listener or throw.
          recorder.tracker.removeCompletionListener(once);
        };
        recorder.tracker
          ..addCompletionListener(once)
          ..addCompletionListener((block) => all.add(block.exitCode));

        terminal.write(_fixture());

        expect(first, [0]);
        expect(all, [0, 7, 7]);
      },
    );
  });
}
