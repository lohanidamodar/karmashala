import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';

import 'fake_instance.dart';
import 'search_layout.dart';

/// Searching every open pane, not only the focused one.
///
/// Cost lives in `terminal_search_cost_test.dart`; this is about what the user
/// gets: which pane a hit came from, and getting there.
void main() {
  late SearchLayout layout;

  setUp(() {
    // Small and shallow: these are behaviour assertions, and the bounds are
    // asserted where they belong.
    layout = SearchLayout(
      panes: 3,
      linesPerPane: 4,
      text: (pane, line) => 'pane $pane line $line',
    );
    addTearDown(layout.dispose);
  });

  String pane(int index) => layout.panes[index];

  int highlightsIn(int index) => layout.sessions
      .instanceFor(pane(index))!
      .controller
      .searchHighlights
      .length;

  test('cross-pane is off by default, and only the open pane is searched', () {
    layout.write(pane(1), 'shared-needle\r\n');
    layout.write(pane(0), 'shared-needle\r\n');

    layout.search
      ..open(pane(0))
      ..setQuery('shared-needle');
    layout.schedule.drain();

    expect(layout.state.crossPane, isFalse);
    expect(layout.state.matchCount, 1, reason: 'pane 1 was not searched');
    expect(layout.state.panesSearched, 1);
  });

  test('a match in a pane that is not focused is attributed to that pane', () {
    layout.write(pane(2), 'only-in-two\r\n');

    layout.search
      ..open(pane(0))
      ..toggleCrossPane()
      ..setQuery('only-in-two');
    expect(layout.state.matchCount, 0, reason: 'not in the open pane');

    layout.schedule.drain();

    expect(layout.state.matchCount, 1);
    expect(layout.state.currentPaneId, pane(2));
    expect(layout.state.currentPaneTitle, isNotNull);
    expect(
      layout.state.paneId,
      pane(0),
      reason: 'the bar is still open against the pane it was opened from',
    );
  });

  test('the open pane keeps its matches first, so its results do not move', () {
    layout.write(pane(0), 'both-panes\r\n');
    layout.write(pane(1), 'both-panes\r\n');

    layout.search
      ..open(pane(0))
      ..toggleCrossPane()
      ..setQuery('both-panes');
    expect(layout.state.currentIndex, 0);
    expect(layout.state.currentPaneId, pane(0));

    layout.schedule.drain();

    expect(layout.state.matchCount, 2);
    expect(
      layout.state.currentIndex,
      0,
      reason: 'the sweep appends, so the selected hit does not shift under you',
    );
    expect(layout.state.currentPaneId, pane(0));
  });

  test('stepping onto another pane moves the highlight there', () {
    layout.write(pane(0), 'both-panes\r\n');
    layout.write(pane(1), 'both-panes\r\n');

    layout.search
      ..open(pane(0))
      ..toggleCrossPane()
      ..setQuery('both-panes');
    layout.schedule.drain();
    expect(highlightsIn(0), 1);
    expect(highlightsIn(1), 0);

    layout.search.next();

    expect(layout.state.currentPaneId, pane(1));
    expect(highlightsIn(1), 1, reason: 'painted where the hit actually is');
    expect(highlightsIn(0), 0, reason: 'and nowhere else');
  });

  test('stepping does not steal the keyboard from the find field', () {
    // Focusing a pane focuses its terminal, which would take the caret out of
    // the query field mid-word. Revealing is a deliberate act, not a side
    // effect of pressing Enter.
    layout.write(pane(1), 'only-in-one\r\n');

    layout.search
      ..open(pane(0))
      ..toggleCrossPane()
      ..setQuery('only-in-one');
    layout.schedule.drain();
    final before = layout.container
        .read(terminalSessionsControllerProvider)
        .activeTab!
        .id;

    layout.search.next();

    expect(
      layout.container.read(terminalSessionsControllerProvider).activeTab!.id,
      before,
      reason: 'stepping moved nothing but the highlight',
    );
  });

  test('revealing a result jumps to the pane it came from', () {
    layout.write(pane(2), 'only-in-two\r\n');

    layout.search
      ..open(pane(0))
      ..toggleCrossPane()
      ..setQuery('only-in-two');
    layout.schedule.drain();
    expect(layout.state.currentPaneId, pane(2));

    layout.search.revealCurrent();

    final sessions = layout.container.read(terminalSessionsControllerProvider);
    expect(sessions.activeTab!.id, layout.tabOf(pane(2)));
    expect(sessions.activeTab!.focusedPaneId, pane(2));
    expect(highlightsIn(2), 1);
  });

  test('revealing with no match anywhere is a no-op', () {
    layout.search
      ..open(pane(0))
      ..toggleCrossPane()
      ..setQuery('nothing-anywhere');
    layout.schedule.drain();

    expect(layout.search.revealCurrent, returnsNormally);
    expect(layout.state.matchCount, 0);
  });

  test('turning cross-pane off drops the other panes results', () {
    layout.write(pane(1), 'only-in-one\r\n');

    layout.search
      ..open(pane(0))
      ..toggleCrossPane()
      ..setQuery('only-in-one');
    layout.schedule.drain();
    expect(layout.state.matchCount, 1);

    layout.search.toggleCrossPane();
    layout.schedule.drain();

    expect(layout.state.crossPane, isFalse);
    expect(layout.state.matchCount, 0);
    expect(layout.state.panesSearched, 1);
    expect(highlightsIn(1), 0);
  });

  test('a detached session is searched too — it is still a live pane', () {
    // Closing a tab detaches its pane rather than killing it, which is the
    // whole point of keep-alive; a build still running in the background is
    // exactly the thing worth finding.
    giveShellHistory(layout.sessions.instanceFor(pane(2))!);
    layout.write(pane(2), 'in-the-background\r\n');
    layout.sessions.closeTab(layout.tabOf(pane(2)));
    expect(
      layout.container.read(terminalSessionsControllerProvider).detached,
      hasLength(1),
      reason: 'the pane really was kept alive, not released',
    );

    layout.search
      ..open(pane(0))
      ..toggleCrossPane()
      ..setQuery('in-the-background');
    layout.schedule.drain();

    expect(layout.state.matchCount, 1);
    expect(layout.state.currentPaneId, pane(2));
  });

  test('regex composes with cross-pane', () {
    layout.write(pane(1), 'exit code 7\r\n');

    layout.search
      ..open(pane(0))
      ..toggleCrossPane()
      ..toggleRegex()
      ..setQuery(r'code \d');
    layout.schedule.drain();

    expect(layout.state.matchCount, 1);
    expect(layout.state.currentPaneId, pane(1));
  });

  test('an invalid pattern arms no sweep at all', () {
    layout.search
      ..open(pane(0))
      ..toggleCrossPane()
      ..toggleRegex()
      ..setQuery('a(');

    expect(layout.state.patternError, isNotNull);
    expect(layout.schedule.pendingCount, 0);
    expect(layout.state.matchCount, 0);
  });
}
