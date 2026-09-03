import 'package:karmashala/src/features/terminal/application/terminal_search_controller.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/domain/pane_layout.dart';
import 'package:karmashala/src/features/terminal/domain/terminal_profile.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_instance.dart';

void main() {
  late ProviderContainer container;
  late TerminalSessionsController sessions;
  late String paneId;

  setUp(() {
    container = fakeTerminalContainer();
    addTearDown(container.dispose);
    sessions = container.read(terminalSessionsControllerProvider.notifier);
    sessions.openTab(TerminalProfile.powerShell);
    paneId = container
        .read(terminalSessionsControllerProvider)
        .activeTab!
        .layout
        .panes
        .single;
    sessions.instanceFor(paneId)!.terminal.write('alpha\r\nbeta\r\nalpha\r\n');
  });

  TerminalSearchController search() =>
      container.read(terminalSearchControllerProvider.notifier);

  TerminalSearchState state() =>
      container.read(terminalSearchControllerProvider);

  int highlightCount() =>
      sessions.instanceFor(paneId)!.controller.searchHighlights.length;

  /// Which painted hit xterm2 gives `searchHitBackgroundCurrent` to, or -1 when
  /// none is painted. This is what makes the selected match tellable from the
  /// rest, so it is asserted rather than left to the colour.
  int currentHighlight() =>
      sessions.instanceFor(paneId)!.controller.currentSearchHighlight;

  test('open then query reports the match count and selects the first', () {
    search()
      ..open(paneId)
      ..setQuery('alpha');

    expect(state().visible, isTrue);
    expect(state().paneId, paneId);
    expect(state().matchCount, 2);
    expect(state().currentIndex, 0);
    expect(highlightCount(), 2);
    expect(currentHighlight(), 0);
  });

  test('next and previous wrap around', () {
    search()
      ..open(paneId)
      ..setQuery('alpha')
      ..next();
    expect(state().currentIndex, 1);

    search().next();
    expect(state().currentIndex, 0, reason: 'wraps past the last match');

    search().previous();
    expect(state().currentIndex, 1, reason: 'wraps back past the first');
  });

  test('stepping moves which highlight is the current one', () {
    // The colour is xterm2's; what this pins is that the selected match keeps
    // its own one as the selection moves, which is the whole point of a find
    // bar with a next button.
    search()
      ..open(paneId)
      ..setQuery('alpha');
    expect(currentHighlight(), 0);

    search().next();
    expect(currentHighlight(), 1);

    search().next();
    expect(currentHighlight(), 0, reason: 'wrapped, and so did the colour');
  });

  test('case sensitivity narrows the results', () {
    sessions.instanceFor(paneId)!.terminal.write('ALPHA\r\n');
    search()
      ..open(paneId)
      ..setQuery('ALPHA');
    expect(state().matchCount, 3);

    search().toggleCaseSensitive();
    expect(state().caseSensitive, isTrue);
    expect(state().matchCount, 1);
  });

  test('an empty query clears matches and highlights', () {
    search()
      ..open(paneId)
      ..setQuery('alpha')
      ..setQuery('');

    expect(state().matchCount, 0);
    expect(highlightCount(), 0);
  });

  test('a query with no hits reports zero without throwing', () {
    search()
      ..open(paneId)
      ..setQuery('nothing here');
    expect(state().matchCount, 0);
    expect(state().currentIndex, 0);
    expect(highlightCount(), 0);
    search()
      ..next()
      ..previous();
    expect(state().matchCount, 0);
  });

  test('highlights are capped and the cap is reported', () {
    final terminal = sessions.instanceFor(paneId)!.terminal;
    for (var i = 0; i < 600; i++) {
      terminal.write('needle\r\n');
    }

    search()
      ..open(paneId)
      ..setQuery('needle');

    expect(state().matchCount, greaterThan(500));
    expect(state().truncated, isTrue);
    expect(highlightCount(), lessThanOrEqualTo(500));
    expect(currentHighlight(), 0);

    // Past the cap the window slides rather than staying on the first 500: the
    // hit the user stepped to must not be the one thing on screen with no
    // colour on it.
    search().previous();

    expect(state().currentIndex, 599, reason: 'wrapped to the last hit');
    expect(highlightCount(), 500, reason: 'still capped');
    expect(
      currentHighlight(),
      499,
      reason: 'and it is the last one painted, not a hit 500 rows above',
    );
  });

  test('close drops every highlight', () {
    search()
      ..open(paneId)
      ..setQuery('alpha')
      ..close();

    expect(state().visible, isFalse);
    expect(highlightCount(), 0);
  });

  test('switching the searched pane clears the previous pane highlights', () {
    search()
      ..open(paneId)
      ..setQuery('alpha');
    expect(highlightCount(), 2);

    final second = sessions.splitPaneWith(
      SplitAxis.horizontal,
      TerminalProfile.commandPrompt,
    )!;
    search().open(second);

    expect(highlightCount(), 0, reason: 'the first pane is no longer searched');
    expect(state().paneId, second);
    expect(state().query, isEmpty);
  });

  test('searching a pane that has gone away is a no-op', () {
    search()
      ..open('a-pane-that-never-existed')
      ..setQuery('alpha');
    expect(state().matchCount, 0);
  });

  group('regex', () {
    test('a pattern finds what a literal query cannot', () {
      sessions.instanceFor(paneId)!.terminal.write('exit code 42\r\n');
      search()
        ..open(paneId)
        ..setQuery(r'code \d+');
      expect(state().matchCount, 0, reason: 'literal by default');

      search().toggleRegex();
      expect(state().regex, isTrue);
      expect(state().matchCount, 1);
      expect(state().patternError, isNull);
    });

    test('an invalid pattern is named, finds nothing, and does not throw', () {
      search()
        ..open(paneId)
        ..toggleRegex();
      expect(() => search().setQuery('alpha('), returnsNormally);

      expect(state().patternError, isNotNull);
      expect(state().matchCount, 0);
      expect(highlightCount(), 0);
      // The trap this closes: falling back to literal matching would report a
      // hit for the text "alpha(" and look authoritative doing it.
      expect(state().hasMatches, isFalse);
    });

    test('an invalid pattern clears once it is completed', () {
      search()
        ..open(paneId)
        ..toggleRegex()
        ..setQuery('(alph')
        ..setQuery('(alph)a');
      expect(state().patternError, isNull);
      expect(state().matchCount, 2);
    });

    test('case sensitivity composes with the pattern', () {
      sessions.instanceFor(paneId)!.terminal.write('ALPHA\r\n');
      search()
        ..open(paneId)
        ..toggleRegex()
        ..setQuery('^alpha');
      expect(state().matchCount, 3, reason: 'folded by default');

      search().toggleCaseSensitive();
      expect(state().matchCount, 2, reason: 'the two lower-case alphas');
    });

    test('turning the toggle off searches the same text literally again', () {
      search()
        ..open(paneId)
        ..toggleRegex()
        ..setQuery('al.ha');
      expect(state().matchCount, 2);

      search().toggleRegex();
      expect(state().regex, isFalse);
      expect(state().matchCount, 0);
      expect(state().patternError, isNull);
    });
  });

  group('the alternate screen', () {
    // What a full-screen program sends to take the screen: save the cursor,
    // clear the alternate buffer, switch to it. `vim`, `htop`, `less` and an
    // agent CLI's own UI all live behind this sequence.
    const enterAlt = '\x1b[?1049h';
    const leaveAlt = '\x1b[?1049l';

    test('a full-screen program\'s own screen is searched', () {
      final terminal = sessions.instanceFor(paneId)!.terminal;
      terminal
        ..write(enterAlt)
        ..write('  PID USER  needle-in-htop\r\n');

      search()
        ..open(paneId)
        ..setQuery('needle-in-htop');

      expect(state().onAlternateScreen, isTrue);
      expect(state().matchCount, 1);
      expect(highlightCount(), 1, reason: 'the hit is on screen, so paint it');
    });

    test('the scrollback behind it is counted rather than silently lost', () {
      // The wrong answer this replaces: "No results", which reads as "that
      // text is not in this pane" when it is — it is just behind vim.
      sessions.instanceFor(paneId)!.terminal.write(enterAlt);

      search()
        ..open(paneId)
        ..setQuery('alpha');

      expect(state().matchCount, 0, reason: 'nothing on the vim screen');
      expect(state().hiddenScrollbackMatches, 2);
      expect(state().onAlternateScreen, isTrue);
    });

    test('a hidden scrollback hit is never highlighted', () {
      // A main-buffer anchor resolves its row against the *main* buffer, so
      // painting one while the alternate screen is up would put a highlight on
      // an unrelated row of somebody else's UI.
      sessions.instanceFor(paneId)!.terminal.write(enterAlt);
      search()
        ..open(paneId)
        ..setQuery('alpha');
      expect(highlightCount(), 0);
    });

    test('leaving the alternate screen brings the scrollback back', () {
      final terminal = sessions.instanceFor(paneId)!.terminal..write(enterAlt);
      search()
        ..open(paneId)
        ..setQuery('alpha');
      expect(state().matchCount, 0);

      terminal.write(leaveAlt);
      search().setQuery('alpha');

      expect(state().onAlternateScreen, isFalse);
      expect(state().matchCount, 2);
      expect(state().hiddenScrollbackMatches, 0);
    });

    test('the stale alternate screen is not searched once its program left', () {
      // xterm's `1049l` does not clear the alternate buffer, so vim's last
      // screen sits there indefinitely. Matching it would report hits for text
      // that is on no screen and cannot be scrolled to.
      sessions.instanceFor(paneId)!.terminal
        ..write(enterAlt)
        ..write('ghost-of-vim\r\n')
        ..write(leaveAlt);

      search()
        ..open(paneId)
        ..setQuery('ghost-of-vim');

      expect(state().matchCount, 0);
      expect(state().hiddenScrollbackMatches, 0);
    });

    test('a program taking the screen re-runs the open search', () {
      search()
        ..open(paneId)
        ..setQuery('alpha');
      expect(state().matchCount, 2);
      expect(highlightCount(), 2);

      sessions.instanceFor(paneId)!.terminal.write(enterAlt);

      expect(state().matchCount, 0, reason: 'those lines are behind it now');
      expect(state().hiddenScrollbackMatches, 2);
      expect(highlightCount(), 0, reason: 'stale anchors would paint on vim');
    });
  });
}
