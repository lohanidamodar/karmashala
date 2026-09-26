import 'package:karmashala_host/karmashala_host.dart';
import 'package:test/test.dart';
import 'package:xterm2/core.dart';

/// A snapshot is only worth sending if a fresh terminal that reads it is the
/// terminal it was taken from — cell for cell, and in what the next bytes do
/// to it. Every case builds a terminal, rebuilds it from its snapshot, and
/// compares the two.
void main() {
  Terminal fresh(int width, int height) =>
      Terminal(maxLines: 1000)..resize(width, height);

  Terminal rebuilt(Terminal from) =>
      fresh(from.viewWidth, from.viewHeight)..write(screenSnapshot(from));

  /// Blank and space read the same when unstyled: a gap written as a space to
  /// keep a wrapped line joined is still a gap.
  int glyph(BufferLine line, int x) {
    final c = line.getCodePoint(x);
    return c == 0x20 ? 0 : c;
  }

  void expectSameBuffer(Buffer a, Buffer b, String which) {
    expect(b.lines.length, a.lines.length, reason: '$which line count');
    for (var y = 0; y < a.lines.length; y++) {
      final la = a.lines[y];
      final lb = b.lines[y];
      expect(lb.isWrapped, la.isWrapped, reason: '$which row $y wrap flag');
      for (var x = 0; x < la.length; x++) {
        final at = '$which row $y col $x';
        expect(glyph(lb, x), glyph(la, x), reason: '$at glyph');
        expect(lb.getWidth(x), la.getWidth(x), reason: '$at width');
        expect(lb.getForeground(x), la.getForeground(x), reason: '$at fg');
        expect(lb.getBackground(x), la.getBackground(x), reason: '$at bg');
        expect(
          lb.getAttributes(x) & CellAttr.visualMask,
          la.getAttributes(x) & CellAttr.visualMask,
          reason: '$at attributes',
        );
      }
    }
  }

  void expectSame(Terminal a, Terminal b) {
    expectSameBuffer(a.mainBuffer, b.mainBuffer, 'main');
    expect(b.isUsingAltBuffer, a.isUsingAltBuffer);
    if (a.isUsingAltBuffer) {
      expectSameBuffer(a.altBuffer, b.altBuffer, 'alt');
    }
    expect(
      (b.buffer.cursorX, b.buffer.cursorY),
      (a.buffer.cursorX, a.buffer.cursorY),
      reason: 'cursor',
    );
    expect(b.cursorVisibleMode, a.cursorVisibleMode);
    expect(b.bracketedPasteMode, a.bracketedPasteMode);
    expect(b.cursorKeysMode, a.cursorKeysMode);
    expect(b.mouseMode, a.mouseMode);
    expect(b.mouseReportMode, a.mouseReportMode);
    expect(b.kittyKeyboardMode, a.kittyKeyboardMode);
    expect(b.autoWrapMode, a.autoWrapMode);
    expect(
      (b.buffer.marginTop, b.buffer.marginBottom),
      (a.buffer.marginTop, a.buffer.marginBottom),
      reason: 'margins',
    );
  }

  test('text, scrollback and the cursor', () {
    final t = fresh(20, 5);
    for (var i = 0; i < 12; i++) {
      t.write('line $i\r\n');
    }
    t.write(r'$ ls -la');
    expectSame(t, rebuilt(t));
  });

  test('colours and attributes of every kind', () {
    final t = fresh(40, 6)
      ..write('\x1b[1;31mbold red\x1b[0m \x1b[3;4;92mital ul\x1b[0m\r\n')
      ..write('\x1b[38;5;208mpal\x1b[48;2;10;20;30mrgb bg\x1b[0m\r\n')
      ..write('\x1b[7minv\x1b[27m \x1b[9mstrike\x1b[0m \x1b[2mfaint\x1b[0m')
      ..write('\x1b[44m    \x1b[0m');
    expectSame(t, rebuilt(t));
  });

  test('a soft-wrapped line stays one logical line', () {
    final t = fresh(10, 5)..write('abcdefghijklmnopqrstuvw\r\nnext');
    final b = rebuilt(t);
    expectSame(t, b);
    b.resize(30, 5);
    expect(
      b.buffer.lines[b.buffer.lines.length - 5].getText().trimRight(),
      'abcdefghijklmnopqrstuvw',
    );
  });

  test('gaps the program moved over, and wide and combining glyphs', () {
    final t = fresh(30, 4)
      ..write('User declined\x1b[17Gto\x1b[20Ganswer\r\n')
      ..write('漢字 wide é combining');
    expectSame(t, rebuilt(t));
  });

  test('the alternate screen, with the main one kept beneath', () {
    final t = fresh(20, 5)
      ..write('shell history\r\n\$ vim\r\n')
      ..write('\x1b[?1049h\x1b[H\x1b[2J~\r\n~ file\x1b[3;5H');
    final b = rebuilt(t);
    expectSame(t, b);
    // Leaving vim restores the main screen and its cursor in both.
    t.write('\x1b[?1049l');
    b.write('\x1b[?1049l');
    expectSame(t, b);
  });

  test('modes a TUI sets', () {
    final t = fresh(20, 5)
      ..write('\x1b[?25l\x1b[?2004h\x1b[?1h\x1b[?1002h\x1b[?1006h')
      ..write('\x1b[>5u\x1b[2;4r\x1b[3;2H');
    expectSame(t, rebuilt(t));
  });

  test('the next redraw of an inline TUI lands the same in both', () {
    // Claude Code's shape: history, a live region below the parked cursor,
    // and a relative redraw of it afterwards.
    const rows = 6;
    String frame(String tag) => [
      '─' * 40,
      '\x1b[38;5;174m❯\x1b[39m $tag',
      '─' * 40,
      '  \x1b[33m⏵⏵ auto mode on\x1b[39m',
      '',
      '  status $tag',
    ].join('\r\n');
    String redraw(String tag) =>
        '\x1b[?2026h\x1b[${rows - 1}B'
        '${'\x1b[2K\x1b[1A' * (rows - 1)}\x1b[2K\r${frame(tag)}'
        '\x1b[${rows - 1}A\r\x1b[?2026l';

    final t = fresh(40, 12);
    for (var i = 0; i < 20; i++) {
      t.write('⏺ transcript $i\r\n');
    }
    t.write('${frame('v1')}\x1b[${rows - 1}A\r');
    final b = rebuilt(t);
    expectSame(t, b);

    t.write(redraw('v2'));
    b.write(redraw('v2'));
    expectSame(t, b);
  });
}
