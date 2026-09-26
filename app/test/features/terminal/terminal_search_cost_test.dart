import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/grid.dart';

import 'search_layout.dart';

/// What **find** costs, counted rather than timed.
///
/// Same house rule as `ingest_throughput_cost_test.dart` and
/// `resume_cost_test.dart`: a stopwatch assertion over a few milliseconds fails
/// when the machine is busy and teaches everyone to re-run it. The unit here is
/// the only one that matters for search — **buffer lines read** — because a
/// line read is a `lineTextOf` flatten plus an `indexOf` or a `RegExp` step,
/// and the search does nothing else.
///
/// The number this exists to keep out of the product: the app's target is 100
/// live panes of up to 10 000 lines. Searching all of them on every keystroke
/// is 1 000 000 line reads per character typed, on the UI isolate, while the
/// terminal is the highest performance priority in the app. So:
///
/// * the pane being searched is scanned **eagerly**, on every keystroke — one
///   pane, which is what today's search already costs;
/// * every other pane waits for the query to settle ([kCrossPaneDebounce]) and
///   is then swept **one pane per slice**, each capped at
///   [kCrossPaneScanLines] lines and the whole sweep at
///   [kCrossPaneMatchBudget] matches.
///
/// Which makes the worst case of one turn of the event loop
/// `kCrossPaneScanLines` — 2 000 lines — regardless of how many panes are open.
/// That is the assertion at the bottom, and it is the one that has to hold at
/// 100 panes.
void main() {
  test('with cross-pane off, typing never leaves the pane being searched', () {
    final layout = SearchLayout(panes: 12, linesPerPane: 2500);
    addTearDown(layout.dispose);
    final focused = layout.panes.first;
    final focusedLines = layout.lineCount(focused);

    layout.search.open(focused);
    for (final prefix in ['l', 'li', 'lin', 'line', 'line ', 'line 4']) {
      layout.search.setQuery(prefix);
    }

    expect(
      layout.state.linesScanned,
      6 * focusedLines,
      reason: 'six keystrokes, one pane each, and no sweep',
    );
    expect(layout.schedule.pendingCount, 0, reason: 'nothing was armed');
    expect(layout.state.panesSearched, 1);
  });

  test('cross-pane does not sweep on every keystroke', () {
    final layout = SearchLayout(panes: 12, linesPerPane: 2500);
    addTearDown(layout.dispose);
    final focused = layout.panes.first;
    final focusedLines = layout.lineCount(focused);

    layout.search
      ..open(focused)
      ..toggleCrossPane();
    for (final prefix in ['l', 'li', 'lin', 'line', 'line ', 'line 4']) {
      layout.search.setQuery(prefix);
    }

    expect(
      layout.state.linesScanned,
      6 * focusedLines,
      reason: 'the other eleven panes have not been touched yet',
    );
    expect(
      layout.schedule.pendingCount,
      1,
      reason: 'one sweep armed for the settled query, not six',
    );
    expect(layout.state.panesPending, 11);
  });

  test('a sweep slice reads one pane, bounded by the scan window', () {
    final layout = SearchLayout(panes: 12, linesPerPane: 2500);
    addTearDown(layout.dispose);
    final focused = layout.panes.first;

    layout.search
      ..open(focused)
      ..toggleCrossPane()
      ..setQuery('line 4');

    final perSlice = <int>[];
    var previous = layout.state.linesScanned;
    while (layout.schedule.step()) {
      perSlice.add(layout.state.linesScanned - previous);
      previous = layout.state.linesScanned;
    }

    expect(perSlice.length, 11, reason: 'eleven other panes, one slice each');
    expect(
      perSlice.reduce((a, b) => a > b ? a : b),
      kCrossPaneScanLines,
      reason: 'a 2 500-line pane is read back only as far as the window',
    );
    expect(
      perSlice.every((lines) => lines <= kCrossPaneScanLines),
      isTrue,
      reason: 'this is the number that has to hold at 100 panes',
    );
    expect(layout.state.panesSearched, 12);
    expect(layout.state.panesPending, 0);
    expect(layout.state.scanning, isFalse);
  });

  test('the whole sweep is bounded by panes times the window', () {
    final layout = SearchLayout(panes: 12, linesPerPane: 2500);
    addTearDown(layout.dispose);
    final focused = layout.panes.first;
    final focusedLines = layout.lineCount(focused);

    layout.search
      ..open(focused)
      ..toggleCrossPane()
      ..setQuery('line 4');
    layout.schedule.drain();

    expect(
      layout.state.linesScanned,
      focusedLines + 11 * kCrossPaneScanLines,
      reason: 'the focused pane in full, every other one bounded',
    );
  });

  test('the match budget stops the sweep before it runs out of panes', () {
    // 'pane' is on every line of every pane, which is the pathological query:
    // without a budget this collects 12 x 2 500 matches and allocates them all.
    final layout = SearchLayout(panes: 12, linesPerPane: 2500);
    addTearDown(layout.dispose);
    final focused = layout.panes.first;

    final focusedLines = layout.lineCount(focused);
    layout.search
      ..open(focused)
      ..toggleCrossPane()
      ..setQuery('pane');
    layout.schedule.drain();

    expect(
      layout.state.panesPending,
      greaterThan(0),
      reason: 'the budget stopped it, and the bar can say so',
    );
    expect(layout.state.scanning, isFalse);
    expect(
      layout.state.linesScanned,
      lessThanOrEqualTo(focusedLines + kCrossPaneScanLines),
      reason: 'twelve panes of hits cost at most one panes window',
    );
  });

  test('closing the bar cancels a sweep that was still armed', () {
    final layout = SearchLayout(panes: 12, linesPerPane: 2500);
    addTearDown(layout.dispose);

    layout.search
      ..open(layout.panes.first)
      ..toggleCrossPane()
      ..setQuery('line 4');
    expect(layout.schedule.pendingCount, 1);

    layout.search.close();

    expect(layout.schedule.pendingCount, 0);
    expect(layout.state.linesScanned, 0);
  });

  test('a pane closed mid-sweep is skipped rather than thrown over', () {
    final layout = SearchLayout(panes: 4, linesPerPane: 2500);
    addTearDown(layout.dispose);

    layout.search
      ..open(layout.panes.first)
      ..toggleCrossPane()
      ..setQuery('line 4');
    // Ended for real rather than detached: a detached pane is still tracked and
    // still searchable, which is not the case being tested.
    layout.sessions.closeTab(layout.tabOf(layout.panes.last), detach: false);

    expect(layout.schedule.drain, returnsNormally);
    expect(layout.state.panesSearched, 3, reason: 'the closed pane is gone');
  });
}
