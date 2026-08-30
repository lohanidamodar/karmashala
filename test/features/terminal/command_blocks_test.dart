import 'package:chitragupta/src/features/terminal/domain/command_blocks.dart';
import 'package:flutter_test/flutter_test.dart';

/// A stand-in for a buffer line whose index can move, or vanish when the line
/// is evicted from scrollback.
class _Ref implements TerminalLineRef {
  _Ref(this._line);
  int? _line;
  void evict() => _line = null;
  @override
  int? get line => _line;
}

DateTime _at(int seconds) => DateTime.utc(2026, 8, 30, 12, 0, seconds);

void main() {
  group('shellMarkerFromOsc', () {
    test('maps the four OSC 133 sub-codes', () {
      expect(shellMarkerFromOsc('133', ['A']), ShellMarker.promptStart);
      expect(shellMarkerFromOsc('133', ['B']), ShellMarker.commandStart);
      expect(shellMarkerFromOsc('133', ['C']), ShellMarker.outputStart);
      expect(shellMarkerFromOsc('133', ['D']), ShellMarker.commandEnd);
      expect(shellMarkerFromOsc('133', ['D', '1']), ShellMarker.commandEnd);
    });

    test('a non-133 OSC is not a marker', () {
      // OSC 7 (working directory) and OSC 9 (notifications) are both things a
      // real shell emits; neither may be read as a command boundary.
      expect(shellMarkerFromOsc('7', ['file:///c/tmp']), isNull);
      expect(shellMarkerFromOsc('9', ['A']), isNull);
    });

    test('an unknown 133 sub-code is ignored', () {
      // OSC 133;E carries the command line in some shells; we do not consume it
      // yet and must not mistake it for a boundary.
      expect(shellMarkerFromOsc('133', ['E', 'ls -la']), isNull);
      expect(shellMarkerFromOsc('133', []), isNull);
      expect(shellMarkerFromOsc('133', ['']), isNull);
    });
  });

  group('exitCodeFromOsc', () {
    test('reads the exit code that follows D', () {
      expect(exitCodeFromOsc(['D', '0']), 0);
      expect(exitCodeFromOsc(['D', '127']), 127);
    });

    test('an absent or unparseable exit code is unknown, not a failure', () {
      expect(exitCodeFromOsc(['D']), isNull);
      expect(exitCodeFromOsc(['D', '']), isNull);
      expect(exitCodeFromOsc(['D', 'nope']), isNull);
    });
  });

  group('CommandBlockTracker', () {
    test('a full A B C D lifecycle produces one completed block', () {
      final tracker = CommandBlockTracker();
      tracker
        ..onMarker(ShellMarker.promptStart, ref: _Ref(10), at: _at(0))
        ..onMarker(ShellMarker.commandStart, ref: _Ref(10), at: _at(0))
        ..onMarker(
          ShellMarker.outputStart,
          ref: _Ref(11),
          at: _at(1),
          command: 'ls -la',
        )
        ..onMarker(
          ShellMarker.commandEnd,
          ref: _Ref(20),
          at: _at(3),
          exitCode: 0,
        );

      expect(tracker.blocks, hasLength(1));
      final block = tracker.blocks.single;
      expect(block.promptLine, 10);
      expect(block.command, 'ls -la');
      expect(block.exitCode, 0);
      expect(block.failed, isFalse);
      expect(block.isRunning, isFalse);
      expect(block.duration, const Duration(seconds: 2));
      expect(tracker.pending, isNull);
    });

    test('a command that has started but not finished is running', () {
      final tracker = CommandBlockTracker();
      tracker
        ..onMarker(ShellMarker.promptStart, ref: _Ref(1), at: _at(0))
        ..onMarker(ShellMarker.outputStart, ref: _Ref(2), at: _at(1));

      expect(tracker.blocks, isEmpty);
      expect(tracker.pending, isNotNull);
      expect(tracker.pending!.isRunning, isTrue);
      expect(tracker.pending!.duration, isNull);
    });

    test('a non-zero exit code marks the block failed', () {
      final tracker = CommandBlockTracker();
      tracker
        ..onMarker(ShellMarker.promptStart, ref: _Ref(1), at: _at(0))
        ..onMarker(ShellMarker.outputStart, ref: _Ref(2), at: _at(0))
        ..onMarker(
          ShellMarker.commandEnd,
          ref: _Ref(3),
          at: _at(1),
          exitCode: 127,
        );

      expect(tracker.blocks.single.exitCode, 127);
      expect(tracker.blocks.single.failed, isTrue);
    });

    test('an unknown exit code is not a failure', () {
      final tracker = CommandBlockTracker();
      tracker
        ..onMarker(ShellMarker.promptStart, ref: _Ref(1), at: _at(0))
        ..onMarker(ShellMarker.outputStart, ref: _Ref(2), at: _at(0))
        ..onMarker(ShellMarker.commandEnd, ref: _Ref(3), at: _at(1));

      expect(tracker.blocks.single.exitCode, isNull);
      expect(
        tracker.blocks.single.failed,
        isFalse,
        reason: 'an unknown code must never be drawn as a failure',
      );
    });

    test('an empty prompt (A then D, with no C) produces no block', () {
      // Measured against real bash: pressing Enter on an empty line emits
      // A ... D;0 A with no C in between. That is not a command.
      final tracker = CommandBlockTracker();
      tracker
        ..onMarker(ShellMarker.promptStart, ref: _Ref(1), at: _at(0))
        ..onMarker(
          ShellMarker.commandEnd,
          ref: _Ref(1),
          at: _at(0),
          exitCode: 0,
        );

      expect(tracker.blocks, isEmpty);
      expect(tracker.pending, isNull);
    });

    test('a block with no B still completes', () {
      // bash emits A, C and D but no B; the command text is simply unknown.
      final tracker = CommandBlockTracker();
      tracker
        ..onMarker(ShellMarker.promptStart, ref: _Ref(4), at: _at(0))
        ..onMarker(ShellMarker.outputStart, ref: _Ref(5), at: _at(0))
        ..onMarker(
          ShellMarker.commandEnd,
          ref: _Ref(6),
          at: _at(2),
          exitCode: 0,
        );

      expect(tracker.blocks, hasLength(1));
      expect(tracker.blocks.single.command, isNull);
      expect(tracker.blocks.single.duration, const Duration(seconds: 2));
    });

    test('D with no pending block is ignored', () {
      // Integration can start mid-stream, so the first thing we see may be a D.
      final tracker = CommandBlockTracker();
      tracker.onMarker(
        ShellMarker.commandEnd,
        ref: _Ref(1),
        at: _at(0),
        exitCode: 0,
      );

      expect(tracker.blocks, isEmpty);
      expect(tracker.pending, isNull);
    });

    test('a second A discards an abandoned pending block', () {
      final tracker = CommandBlockTracker();
      tracker
        ..onMarker(ShellMarker.promptStart, ref: _Ref(1), at: _at(0))
        ..onMarker(ShellMarker.promptStart, ref: _Ref(2), at: _at(1));

      expect(tracker.blocks, isEmpty);
      expect(tracker.pending!.promptLine, 2);
    });

    test('a second A keeps a pending block that had already started', () {
      // Ctrl+C between C and D: the command really ran, so it is worth keeping,
      // with an unknown exit code rather than a fabricated one.
      final tracker = CommandBlockTracker();
      tracker
        ..onMarker(ShellMarker.promptStart, ref: _Ref(1), at: _at(0))
        ..onMarker(ShellMarker.outputStart, ref: _Ref(2), at: _at(1))
        ..onMarker(ShellMarker.promptStart, ref: _Ref(9), at: _at(4));

      expect(tracker.blocks, hasLength(1));
      expect(tracker.blocks.single.exitCode, isNull);
      expect(tracker.blocks.single.endedAt, _at(4));
      expect(tracker.pending!.promptLine, 9);
    });

    test('blocks whose line has been evicted are pruned', () {
      final tracker = CommandBlockTracker();
      final evicted = _Ref(1);
      tracker
        ..onMarker(ShellMarker.promptStart, ref: evicted, at: _at(0))
        ..onMarker(ShellMarker.outputStart, ref: _Ref(2), at: _at(0))
        ..onMarker(
          ShellMarker.commandEnd,
          ref: _Ref(3),
          at: _at(1),
          exitCode: 0,
        )
        ..onMarker(ShellMarker.promptStart, ref: _Ref(4), at: _at(2))
        ..onMarker(ShellMarker.outputStart, ref: _Ref(5), at: _at(2))
        ..onMarker(
          ShellMarker.commandEnd,
          ref: _Ref(6),
          at: _at(3),
          exitCode: 0,
        );
      expect(tracker.blocks, hasLength(2));

      evicted.evict();
      tracker.pruneEvicted();

      expect(tracker.blocks, hasLength(1));
      expect(tracker.blocks.single.promptLine, 4);
    });

    test('the block list is capped, trimming the oldest', () {
      final tracker = CommandBlockTracker(maxBlocks: 3);
      for (var i = 0; i < 5; i++) {
        tracker
          ..onMarker(ShellMarker.promptStart, ref: _Ref(i * 10), at: _at(i))
          ..onMarker(ShellMarker.outputStart, ref: _Ref(i * 10), at: _at(i))
          ..onMarker(
            ShellMarker.commandEnd,
            ref: _Ref(i * 10),
            at: _at(i),
            exitCode: 0,
          );
      }

      expect(tracker.blocks, hasLength(3));
      expect(tracker.blocks.map((b) => b.promptLine), [
        20,
        30,
        40,
      ], reason: 'the oldest blocks are dropped, newest kept');
    });

    test('every block gets a distinct id', () {
      final tracker = CommandBlockTracker();
      for (var i = 0; i < 3; i++) {
        tracker
          ..onMarker(ShellMarker.promptStart, ref: _Ref(i), at: _at(i))
          ..onMarker(ShellMarker.outputStart, ref: _Ref(i), at: _at(i))
          ..onMarker(
            ShellMarker.commandEnd,
            ref: _Ref(i),
            at: _at(i),
            exitCode: 0,
          );
      }

      expect(tracker.blocks.map((b) => b.id).toSet(), hasLength(3));
    });
  });
}
