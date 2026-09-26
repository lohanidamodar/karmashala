import 'package:karmashala/src/features/terminal/application/terminal_scroll.dart';
import 'package:karmashala_terminal_core/shell_integration.dart';
import 'package:karmashala/src/features/terminal/presentation/command_history_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Ref implements TerminalLineRef {
  _Ref(this.line);
  @override
  final int? line;
}

DateTime _at(int s) => DateTime.utc(2026, 8, 30, 12, 0, s);

CommandBlockTracker _trackerWith(List<({int line, int? exit})> commands) {
  final tracker = CommandBlockTracker();
  for (final c in commands) {
    tracker
      ..onMarker(ShellMarker.promptStart, ref: _Ref(c.line), at: _at(0))
      ..onMarker(
        ShellMarker.outputStart,
        ref: _Ref(c.line),
        at: _at(0),
        command: 'cmd at ${c.line}',
      )
      ..onMarker(
        ShellMarker.commandEnd,
        ref: _Ref(c.line + 1),
        at: _at(2),
        exitCode: c.exit,
      );
  }
  return tracker;
}

void main() {
  group('terminalLineOffset', () {
    test('centres the line in the viewport', () {
      // 100 lines of 10px in a 200px viewport: content 1000, max scroll 800.
      final offset = terminalLineOffset(
        line: 50,
        lineCount: 100,
        maxScrollExtent: 800,
        viewportDimension: 200,
      );
      // 50 * 10 - 200/2 + 10/2 = 500 - 100 + 5 = 405
      expect(offset, 405);
    });

    test('clamps to the top and the bottom', () {
      expect(
        terminalLineOffset(
          line: 0,
          lineCount: 100,
          maxScrollExtent: 800,
          viewportDimension: 200,
        ),
        0,
      );
      expect(
        terminalLineOffset(
          line: 99,
          lineCount: 100,
          maxScrollExtent: 800,
          viewportDimension: 200,
        ),
        800,
      );
    });

    test('returns null when there is nothing to scroll', () {
      expect(
        terminalLineOffset(
          line: 3,
          lineCount: 10,
          maxScrollExtent: 0,
          viewportDimension: 200,
        ),
        isNull,
      );
      expect(
        terminalLineOffset(
          line: 3,
          lineCount: 0,
          maxScrollExtent: 800,
          viewportDimension: 200,
        ),
        isNull,
      );
    });
  });

  group('command navigation', () {
    test('next and previous pick the neighbouring command', () {
      final tracker = _trackerWith([
        (line: 10, exit: 0),
        (line: 20, exit: 1),
        (line: 30, exit: 0),
      ]);

      expect(tracker.nextAfter(10)?.promptLine, 20);
      expect(tracker.nextAfter(25)?.promptLine, 30);
      expect(tracker.nextAfter(30), isNull);

      expect(tracker.previousBefore(30)?.promptLine, 20);
      expect(tracker.previousBefore(15)?.promptLine, 10);
      expect(tracker.previousBefore(10), isNull);
    });

    test('navigation skips commands whose line has been evicted', () {
      final tracker = CommandBlockTracker();
      tracker
        ..onMarker(ShellMarker.promptStart, ref: _Ref(null), at: _at(0))
        ..onMarker(ShellMarker.outputStart, ref: _Ref(null), at: _at(0))
        ..onMarker(
          ShellMarker.commandEnd,
          ref: _Ref(1),
          at: _at(1),
          exitCode: 0,
        )
        ..onMarker(ShellMarker.promptStart, ref: _Ref(40), at: _at(2))
        ..onMarker(ShellMarker.outputStart, ref: _Ref(40), at: _at(2))
        ..onMarker(
          ShellMarker.commandEnd,
          ref: _Ref(41),
          at: _at(3),
          exitCode: 0,
        );

      expect(tracker.nextAfter(0)?.promptLine, 40);
      expect(tracker.previousBefore(100)?.promptLine, 40);
    });
  });

  group('formatCommandDuration', () {
    test('reads naturally at each scale', () {
      expect(formatCommandDuration(const Duration(milliseconds: 340)), '340ms');
      expect(formatCommandDuration(const Duration(milliseconds: 1234)), '1.2s');
      expect(formatCommandDuration(const Duration(seconds: 45)), '45.0s');
      expect(formatCommandDuration(const Duration(seconds: 125)), '2m 05s');
    });
  });

  group('CommandHistorySheet', () {
    Future<void> pump(WidgetTester tester, CommandBlockTracker tracker) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CommandHistorySheet(
                blocks: tracker.blocks,
                onSelect: (_) {},
              ),
            ),
          ),
        );

    testWidgets('marks a failed command and leaves a successful one alone', (
      tester,
    ) async {
      await pump(
        tester,
        _trackerWith([(line: 10, exit: 0), (line: 20, exit: 127)]),
      );

      expect(find.text('cmd at 10'), findsOneWidget);
      expect(find.text('cmd at 20'), findsOneWidget);
      // The exit code is shown only for the failure, and shown as a number
      // rather than relying on colour alone.
      expect(find.text('exit 127'), findsOneWidget);
      expect(find.textContaining('exit 0'), findsNothing);
    });

    testWidgets('shows a duration for every command', (tester) async {
      await pump(tester, _trackerWith([(line: 10, exit: 0)]));
      expect(find.text('2.0s'), findsOneWidget);
    });

    testWidgets('an unknown exit code is not shown as a failure', (
      tester,
    ) async {
      await pump(tester, _trackerWith([(line: 10, exit: null)]));
      expect(find.textContaining('exit'), findsNothing);
    });

    testWidgets('renders an empty state rather than nothing at all', (
      tester,
    ) async {
      await pump(tester, CommandBlockTracker());
      expect(find.textContaining('No commands'), findsOneWidget);
    });

    testWidgets('selecting a command reports it', (tester) async {
      CommandBlock? picked;
      final tracker = _trackerWith([(line: 10, exit: 0)]);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CommandHistorySheet(
              blocks: tracker.blocks,
              onSelect: (b) => picked = b,
            ),
          ),
        ),
      );

      await tester.tap(find.text('cmd at 10'));
      await tester.pump();

      expect(picked?.promptLine, 10);
    });
  });
}
