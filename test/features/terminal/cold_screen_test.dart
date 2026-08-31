import 'dart:convert';
import 'dart:typed_data';

import 'package:chitragupta/src/features/terminal/data/cold_screen.dart';
import 'package:chitragupta/src/features/terminal/data/scrollback_park.dart';
import 'package:chitragupta/src/features/terminal/data/terminal_grid_text.dart';
import 'package:chitragupta/src/features/terminal/data/terminal_ingest_budget.dart';
import 'package:chitragupta/src/features/terminal/domain/ingest_tier.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// A detached pane must not go blind just because nobody has a tab open on it.
///
/// Visibility-aware ingestion stopped parsing a cold pane altogether and sent
/// its bytes to a spool instead — which is right for the *scrollback*, and
/// wrong for the *screen*. `terminalTailLines` reads the bottom of the grid to
/// tell whether an agent is waiting for approval, and a session with no tab is
/// exactly the session nobody is watching for. Freezing its grid at the moment
/// it was detached is behaviour that only works while a pane is visible, which
/// at a hundred sessions is behaviour that mostly does not work.
///
/// So a cold pane keeps its *screen* current and nothing else: at most one
/// parse per [kColdScreenRefreshInterval], out of the same shared background
/// pool a warm pane draws on, trimmed straight back to the viewport.
void main() {
  Uint8List utf8Bytes(String text) => const Utf8Encoder().convert(text);

  ({Terminal terminal, ScrollbackPark park, ColdScreen screen, void Function(Duration) advance})
  coldPane({
    TerminalIngestBudget? budget,
    int rows = 10,
    int maxPendingBytes = kColdScreenPendingMaxBytes,
  }) {
    var now = Duration.zero;
    final terminal = Terminal(maxLines: 1000)..resize(40, rows);
    for (var i = 0; i < 200; i++) {
      terminal.write('history line $i\r\n');
    }
    final park = ScrollbackPark(terminal)..park();
    final screen = ColdScreen(
      terminal: terminal,
      park: park,
      budget: budget ?? TerminalIngestBudget(clock: () => now),
      clock: () => now,
      maxPendingBytes: maxPendingBytes,
    );
    return (
      terminal: terminal,
      park: park,
      screen: screen,
      advance: (by) => now += by,
    );
  }

  test('output arriving while detached reaches the status sources', () {
    final pane = coldPane();

    pane.screen.add(utf8Bytes('Do you want to proceed?\r\n'));

    expect(
      terminalTailLines(pane.terminal).join('\n'),
      contains('Do you want to proceed?'),
      reason:
          'an approval prompt that arrives after the tab was closed is the '
          'whole reason the grid source exists',
    );
  });

  test('keeping the screen current does not grow the buffer back', () {
    final pane = coldPane();
    final parked = pane.terminal.mainBuffer.lines.length;

    for (var i = 0; i < 500; i++) {
      pane.screen.add(utf8Bytes('detached output line $i\r\n'));
      pane.advance(kColdScreenRefreshInterval);
    }

    expect(
      pane.terminal.mainBuffer.lines.length,
      parked,
      reason:
          'the floor is the viewport; a cold pane that refreshes its screen '
          'five hundred times must still cost one screen',
    );
    expect(
      terminalTailLines(pane.terminal).join('\n'),
      contains('detached output line 499'),
    );
  });

  test('a burst refreshes once, not once per chunk', () {
    final pane = coldPane();

    // The first bytes after a quiet moment go through at once — a detached
    // session that has just said something must not wait out an interval.
    pane.screen.add(utf8Bytes('first\r\n'));
    expect(pane.screen.refreshes, 1);

    for (var i = 0; i < 100; i++) {
      pane.screen.add(utf8Bytes('burst $i\r\n'));
    }
    expect(
      pane.screen.refreshes,
      1,
      reason: 'a hundred chunks inside one interval is one parse',
    );

    pane.advance(kColdScreenRefreshInterval);
    pane.screen.add(utf8Bytes('after\r\n'));
    expect(pane.screen.refreshes, 2);
    expect(terminalTailLines(pane.terminal).join('\n'), contains('after'));
  });

  test('a hundred cold panes share one pool rather than each having one', () {
    var now = Duration.zero;
    final budget = TerminalIngestBudget(
      warmPoolBytes: 4096,
      clock: () => now,
    );
    final panes = [
      for (var i = 0; i < 100; i++) coldPane(budget: budget),
    ];

    for (final pane in panes) {
      pane.screen.add(utf8Bytes('x' * 1000));
    }

    expect(
      budget.granted[IngestTier.cold],
      lessThanOrEqualTo(4096),
      reason:
          'a per-pane allowance is what made a hundred hidden panes cost a '
          'hundred times one pane',
    );
    expect(
      [for (final pane in panes) pane.screen.refreshes].fold(0, (a, b) => a + b),
      lessThan(100),
      reason: 'the pool ran out, and the panes that missed it simply waited',
    );
  });

  test('an oversized burst keeps the tail, which is what a screen is', () {
    final pane = coldPane(maxPendingBytes: 512);

    for (var i = 0; i < 200; i++) {
      pane.screen.add(utf8Bytes('line $i\r\n'));
    }
    pane.advance(kColdScreenRefreshInterval);
    pane.screen.add(utf8Bytes('last\r\n'));

    final tail = terminalTailLines(pane.terminal).join('\n');
    expect(tail, contains('last'));
    expect(
      tail,
      isNot(contains('line 0')),
      reason: 'the front was dropped, because a screen only needs the end',
    );
  });

  test('a pane on the alternate buffer is left exactly as it was', () {
    var now = Duration.zero;
    final terminal = Terminal(maxLines: 1000)..resize(40, 10);
    for (var i = 0; i < 200; i++) {
      terminal.write('history line $i\r\n');
    }
    // A full-screen program owns the display: parking refuses, because there is
    // no way to write a snapshot back into a main buffer that is not in front.
    terminal.write('\x1b[?1049h');
    final park = ScrollbackPark(terminal)..park();
    expect(park.isParked, isFalse);
    final before = terminal.mainBuffer.lines.length;

    ColdScreen(
      terminal: terminal,
      park: park,
      budget: TerminalIngestBudget(clock: () => now),
      clock: () => now,
    ).add(utf8Bytes('tui redraw\r\n'));

    expect(
      terminal.mainBuffer.lines.length,
      before,
      reason:
          'the reattach replay is what redraws a TUI, and a half-applied '
          'redraw underneath it would only be applied twice',
    );
  });

  test('a notice the app wrote itself is never held back', () {
    final pane = coldPane();
    pane.screen.add(utf8Bytes('busy\r\n'));
    final refreshes = pane.screen.refreshes;

    // Inside the interval, so an ordinary chunk would wait — and nothing more
    // is ever going to arrive to carry it, because the process has exited.
    pane.screen.write('[process exited with code 0]\r\n');

    expect(pane.screen.refreshes, refreshes + 1);
    expect(
      terminalTailLines(pane.terminal).join('\n'),
      contains('[process exited with code 0]'),
    );
  });

  test('coming back does not leave anything behind to be written twice', () {
    final pane = coldPane();
    pane.screen.add(utf8Bytes('while detached\r\n'));

    pane.screen.reset();
    pane.park.unpark();

    expect(pane.screen.pendingBytes, 0);
    // The parked window is what the buffer holds now; the spool replay is what
    // puts the detached output back, and it must not find a second copy of it
    // already on the screen.
    final text = pane.terminal.mainBuffer.getText();
    expect(text, contains('history line 199'));
    expect(text, isNot(contains('while detached')));
  });

  test('a split multi-byte character survives the boundary', () {
    final pane = coldPane();
    final bytes = utf8Bytes('héllo\r\n');
    // Cut inside the two-byte 'é'.
    pane.screen.add(Uint8List.sublistView(bytes, 0, 2));
    pane.advance(kColdScreenRefreshInterval);
    pane.screen.add(Uint8List.sublistView(bytes, 2));

    expect(terminalTailLines(pane.terminal).join('\n'), contains('héllo'));
  });
}
