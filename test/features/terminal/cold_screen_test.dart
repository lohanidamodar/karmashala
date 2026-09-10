import 'dart:convert';
import 'dart:typed_data';

import 'package:karmashala/src/features/terminal/data/cold_screen.dart';
import 'package:karmashala/src/features/terminal/data/scrollback_park.dart';
import 'package:karmashala/src/features/terminal/data/terminal_grid_text.dart';
import 'package:karmashala/src/features/terminal/data/terminal_ingest_budget.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/xterm.dart';

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

  /// The main buffer's text, whichever buffer is currently in front — which is
  /// the distinction these tests are about.
  String mainBufferText(Terminal terminal) {
    final lines = terminal.mainBuffer.lines;
    return [
      for (var y = 0; y < lines.length; y++) lines[y].getText(),
    ].join('\n');
  }

  ({Terminal terminal, ScrollbackPark park, ColdScreen screen, void Function(Duration) advance})
  coldPane({
    TerminalIngestBudget? budget,
    int rows = 10,
    int maxPendingBytes = kColdScreenPendingMaxBytes,
    bool altBuffer = false,
  }) {
    var now = Duration.zero;
    final terminal = Terminal(maxLines: 1000)..resize(40, rows);
    for (var i = 0; i < 200; i++) {
      terminal.write('history line $i\r\n');
    }
    if (altBuffer) {
      // What an agent CLI does: take the display and draw the whole screen.
      terminal.write('\x1b[?1049h');
      // Ends the line, so what a refresh draws next starts in column zero and
      // the assertions below are about content rather than about wrapping.
      terminal.write('the frame it was detached on\r\n');
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

  test('the history a pane on the alternate buffer kept is not touched', () {
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
          'the redraw goes to the buffer the program is drawing into, and the '
          'main buffer holds the only copy of a history nothing snapshotted',
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

  group('a pane a full-screen program owns', () {
    test('keeps its screen current, exactly as a main-buffer pane does', () {
      final normal = coldPane();
      final tui = coldPane(altBuffer: true);
      expect(normal.park.isParked, isTrue);
      expect(
        tui.park.isParked,
        isFalse,
        reason: 'the park declines a pane it cannot write a snapshot back into',
      );

      for (final pane in [normal, tui]) {
        pane.screen.add(utf8Bytes('Do you want to proceed?\r\n'));
      }

      expect(
        terminalTailLines(normal.terminal).join('\n'),
        contains('Do you want to proceed?'),
      );
      expect(
        terminalTailLines(tui.terminal).join('\n'),
        contains('Do you want to proceed?'),
        reason:
            'an agent CLI draws its own full-screen UI, so the detached panes '
            'whose approval prompts matter most were exactly the frozen ones',
      );
    });

    test('a hundred of them still cost one pool, not a hundred', () {
      var now = Duration.zero;
      final budget = TerminalIngestBudget(warmPoolBytes: 4096, clock: () => now);
      final panes = [
        for (var i = 0; i < 100; i++) coldPane(budget: budget, altBuffer: true),
      ];

      for (final pane in panes) {
        pane.screen.add(utf8Bytes('x' * 1000));
      }

      expect(
        budget.granted[IngestTier.cold],
        lessThanOrEqualTo(4096),
        reason:
            'a hundred detached agents each drawing a full-screen UI is the '
            'scale target, and refreshing them is one pool like any other',
      );
      expect(
        [for (final pane in panes) pane.screen.refreshes].fold(0, (a, b) => a + b),
        lessThan(100),
        reason: 'the pool ran out, and the panes that missed it simply waited',
      );
    });

    test('does not go on showing the frame it was detached on', () {
      final tui = coldPane(altBuffer: true);

      // A TUI repaints absolutely: erase the screen, home the cursor, redraw.
      tui.screen.add(utf8Bytes('\x1b[2J\x1b[Hesc to interrupt\r\n'));

      final tail = terminalTailLines(tui.terminal).join('\n');
      expect(tail, contains('esc to interrupt'));
      expect(
        tail,
        isNot(contains('the frame it was detached on')),
        reason:
            'a grid read at detach and never again is exactly the failure '
            'ColdScreen exists to prevent',
      );
    });
  });

  group('coming back', () {
    ColdIngest coldIngest({
      bool altBuffer = false,
      Duration refreshInterval = Duration.zero,
      IngestClock? clock,
    }) {
      final terminal = Terminal(maxLines: 1000)..resize(40, 10);
      for (var i = 0; i < 200; i++) {
        terminal.write('history line $i\r\n');
      }
      if (altBuffer) terminal.write('\x1b[?1049h');
      return ColdIngest(
        terminal: terminal,
        budget: TerminalIngestBudget(clock: clock ?? () => Duration.zero),
        clock: clock,
        refreshInterval: refreshInterval,
      )..detach(Uint8List(0));
    }

    test('a pane the park declined draws what arrived once, not twice', () {
      final cold = coldIngest(altBuffer: true);
      expect(cold.isParked, isFalse);

      cold.add(utf8Bytes('esc to interrupt\r\n'));
      expect(
        cold.spooledBytes,
        0,
        reason:
            'nothing spooled is how nothing can be replayed over the top of '
            'what the refresh already drew',
      );

      cold.reattach();

      expect(
        'esc to interrupt'.allMatches(cold.terminal.buffer.getText()).length,
        1,
      );
    });

    test('what the interval was still holding back is flushed, not lost', () {
      var now = Duration.zero;
      final cold = coldIngest(
        altBuffer: true,
        refreshInterval: kColdScreenRefreshInterval,
        clock: () => now,
      );

      cold.add(utf8Bytes('first frame\r\n'));
      // Inside the interval, so an ordinary chunk waits for the next one — and
      // for a pane with no spool behind it, reattach is that next one.
      cold.add(utf8Bytes('esc to interrupt\r\n'));
      expect(cold.screen.pendingBytes, greaterThan(0));

      cold.reattach();

      expect(cold.screen.pendingBytes, 0);
      final text = cold.terminal.buffer.getText();
      expect('esc to interrupt'.allMatches(text).length, 1);
      expect('first frame'.allMatches(text).length, 1);
    });

    test('a parked pane still rebuilds itself from the whole spool', () {
      final cold = coldIngest();
      cold.add(utf8Bytes('while detached\r\n'));
      expect(cold.spooledBytes, greaterThan(0));

      cold.reattach();

      final text = cold.terminal.mainBuffer.getText();
      expect(
        'while detached'.allMatches(text).length,
        1,
        reason: 'the unpark clears the buffer, so only the replay survives',
      );
      expect(text, contains('history line 199'), reason: 'history came back');
    });
  });

  group('a pane that starts a full-screen program after it was detached', () {
    /// A pane parked **on the main buffer** — so it really did give its
    /// scrollback up — whose process then takes the screen while nobody is
    /// looking. The order is the whole bug: park first, alt buffer second.
    ColdIngest detachedAtAShell() {
      final terminal = Terminal(maxLines: 1000)..resize(40, 10);
      for (var i = 0; i < 200; i++) {
        terminal.write('history line $i\r\n');
      }
      final cold = ColdIngest(terminal: terminal);
      // The real entry into cold, so the park happens exactly as it does in a
      // pane rather than being simulated.
      cold.detach(Uint8List(0));
      return cold;
    }

    test('keeps the scrollback it parked', () {
      final cold = detachedAtAShell();
      expect(cold.park.isParked, isTrue, reason: 'it was on the main buffer');

      // The program takes the screen while the pane is cold. `ColdScreen`
      // parses this to keep the grid current, so by the time anyone reattaches
      // the terminal is on the alternate buffer — and `unpark` writes with
      // `terminal.write`, which goes to whichever buffer is in front.
      cold.add(const Utf8Encoder().convert('\x1b[?1049hTUI FRAME\r\n'));
      cold.screen.flush();
      expect(cold.terminal.isUsingAltBuffer, isTrue);

      cold.reattach();

      expect(
        mainBufferText(cold.terminal),
        contains('history line 199'),
        reason: 'the parked snapshot must land in the buffer it came from',
      );
    });

    test('and leaves the program on the screen it took', () {
      final cold = detachedAtAShell();
      cold.add(const Utf8Encoder().convert('\x1b[?1049hTUI FRAME\r\n'));
      cold.screen.flush();

      cold.reattach();

      // The process believes it owns the display. Coming back must not hand it
      // a screen switch it never asked for — its next write would land in the
      // scrollback rather than on its own screen.
      expect(cold.terminal.isUsingAltBuffer, isTrue);
    });

    test('and does not disturb a pane that never left the main buffer', () {
      final cold = detachedAtAShell();
      cold.add(const Utf8Encoder().convert('ordinary output\r\n'));
      cold.screen.flush();

      cold.reattach();

      expect(cold.terminal.isUsingAltBuffer, isFalse);
      final text = mainBufferText(cold.terminal);
      expect(text, contains('history line 199'));
      expect(text, contains('ordinary output'));
    });
  });
}
