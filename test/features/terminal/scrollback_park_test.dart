import 'package:chitragupta/src/features/terminal/data/scrollback_park.dart';
import 'package:chitragupta/src/features/terminal/domain/scrollback_limits.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// Parking is what makes a detached pane cost the screen rather than the whole
/// scrollback. It has to give the memory back for real, and it has to give the
/// history back when the session comes home.
void main() {
  const columns = 80;
  const rows = 24;

  Terminal filled(int lines) {
    final terminal = Terminal(maxLines: kLiveScrollbackMaxLines)
      ..resize(columns, rows);
    for (var i = 0; i < lines; i++) {
      terminal.write('line $i\r\n');
    }
    return terminal;
  }

  int residentCellBytes(Terminal terminal) {
    final lines = terminal.mainBuffer.lines;
    var bytes = 0;
    for (var i = 0; i < lines.length; i++) {
      bytes += lines[i].data.lengthInBytes;
    }
    return bytes;
  }

  test('parking releases everything above the screen', () {
    final terminal = filled(500);
    final before = residentCellBytes(terminal);
    final park = ScrollbackPark(terminal);

    expect(park.park(), isTrue);

    expect(terminal.mainBuffer.lines.length, rows);
    expect(
      residentCellBytes(terminal),
      lessThan(before ~/ 10),
      reason: 'the lines have to actually go, not just stop being addressed',
    );
    expect(park.isParked, isTrue);
  });

  test(
    'the screen survives parking, so the status sources can still read it',
    () {
      final terminal = filled(500);
      final park = ScrollbackPark(terminal)..park();

      // The bottom of the grid is what `terminalTailLines` reads to tell
      // "waiting for approval" from "still working".
      expect(terminal.buffer.getText(), contains('line 499'));
      expect(park.isParked, isTrue);
    },
  );

  test('unparking rebuilds a bounded recent window, newest content intact', () {
    final terminal = filled(500);
    final park = ScrollbackPark(terminal)..park();

    park.unpark();

    final text = terminal.mainBuffer.getText();
    expect(text, contains('line 499'));
    expect(text, contains('line 400'));
    expect(park.isParked, isFalse);
    expect(park.parked, isNull);
  });

  test('unparking does not stack a second copy of the kept screen', () {
    final terminal = filled(500);
    ScrollbackPark(terminal)
      ..park()
      ..unpark();

    final text = terminal.mainBuffer.getText();
    expect(
      'line 499\n'.allMatches('$text\n').length,
      1,
      reason: 'the kept screen is the tail of the snapshot, not extra content',
    );
  });

  test('the window is bounded by the cold budget, not by the live one', () {
    final terminal = filled(kLiveScrollbackMaxLines);
    final park = ScrollbackPark(terminal)..park();

    park.unpark();

    expect(
      terminal.mainBuffer.lines.length,
      lessThanOrEqualTo(kColdScrollbackMaxLines + rows + 1),
    );
    expect(terminal.mainBuffer.getText(), contains('line 9999'));
  });

  test('a pane running a full-screen program is left alone', () {
    final terminal = filled(500)..write('\x1b[?1049h');
    expect(terminal.isUsingAltBuffer, isTrue);
    final linesBefore = terminal.mainBuffer.lines.length;

    final park = ScrollbackPark(terminal);

    expect(park.park(), isFalse);
    expect(park.parked, isNull);
    expect(
      terminal.mainBuffer.lines.length,
      linesBefore,
      reason:
          'there is no way to write a snapshot back into a background '
          'buffer, so its history must not be dropped',
    );
  });

  test('a pane with nothing above the screen still parks its window', () {
    final terminal = filled(3);
    final park = ScrollbackPark(terminal);

    expect(
      park.park(),
      isFalse,
      reason: 'nothing was evicted, so nothing anchored to it need be dropped',
    );
    expect(park.parked, contains('line 2'));

    park.unpark();
    expect(terminal.mainBuffer.getText(), contains('line 2'));
  });

  test('parking twice keeps the first window', () {
    final terminal = filled(500);
    final park = ScrollbackPark(terminal)..park();
    final first = park.parked;

    expect(park.park(), isFalse);
    expect(park.parked, same(first));
  });
}
