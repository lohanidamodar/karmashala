import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';

import 'fake_instance.dart';
import 'search_workspace.dart';

/// Searching every open pane, not only the focused one.
///
/// Cost lives in `terminal_search_cost_test.dart`; this is about what the user
/// gets: which pane a hit came from, and getting there.
void main() {
  late SearchWorkspace workspace;

  setUp(() {
    // Small and shallow: these are behaviour assertions, and the bounds are
    // asserted where they belong.
    workspace = SearchWorkspace(
      panes: 3,
      linesPerPane: 4,
      text: (pane, line) => 'pane $pane line $line',
    );
    addTearDown(workspace.dispose);
  });

  String pane(int index) => workspace.panes[index];

  int highlightsIn(int index) =>
      workspace.sessions.instanceFor(pane(index))!.controller.highlights.length;

  test('cross-pane is off by default, and only the open pane is searched', () {
    workspace.write(pane(1), 'shared-needle\r\n');
    workspace.write(pane(0), 'shared-needle\r\n');

    workspace.search
      ..open(pane(0))
      ..setQuery('shared-needle');
    workspace.schedule.drain();

    expect(workspace.state.crossPane, isFalse);
    expect(workspace.state.matchCount, 1, reason: 'pane 1 was not searched');
    expect(workspace.state.panesSearched, 1);
  });

  test('a match in a pane that is not focused is attributed to that pane', () {
    workspace.write(pane(2), 'only-in-two\r\n');

    workspace.search
      ..open(pane(0))
      ..toggleCrossPane()
      ..setQuery('only-in-two');
    expect(workspace.state.matchCount, 0, reason: 'not in the open pane');

    workspace.schedule.drain();

    expect(workspace.state.matchCount, 1);
    expect(workspace.state.currentPaneId, pane(2));
    expect(workspace.state.currentPaneTitle, isNotNull);
    expect(
      workspace.state.paneId,
      pane(0),
      reason: 'the bar is still open against the pane it was opened from',
    );
  });

  test('the open pane keeps its matches first, so its results do not move', () {
    workspace.write(pane(0), 'both-panes\r\n');
    workspace.write(pane(1), 'both-panes\r\n');

    workspace.search
      ..open(pane(0))
      ..toggleCrossPane()
      ..setQuery('both-panes');
    expect(workspace.state.currentIndex, 0);
    expect(workspace.state.currentPaneId, pane(0));

    workspace.schedule.drain();

    expect(workspace.state.matchCount, 2);
    expect(
      workspace.state.currentIndex,
      0,
      reason: 'the sweep appends, so the selected hit does not shift under you',
    );
    expect(workspace.state.currentPaneId, pane(0));
  });

  test('stepping onto another pane moves the highlight there', () {
    workspace.write(pane(0), 'both-panes\r\n');
    workspace.write(pane(1), 'both-panes\r\n');

    workspace.search
      ..open(pane(0))
      ..toggleCrossPane()
      ..setQuery('both-panes');
    workspace.schedule.drain();
    expect(highlightsIn(0), 1);
    expect(highlightsIn(1), 0);

    workspace.search.next();

    expect(workspace.state.currentPaneId, pane(1));
    expect(highlightsIn(1), 1, reason: 'painted where the hit actually is');
    expect(highlightsIn(0), 0, reason: 'and nowhere else');
  });

  test('stepping does not steal the keyboard from the find field', () {
    // Focusing a pane focuses its terminal, which would take the caret out of
    // the query field mid-word. Revealing is a deliberate act, not a side
    // effect of pressing Enter.
    workspace.write(pane(1), 'only-in-one\r\n');

    workspace.search
      ..open(pane(0))
      ..toggleCrossPane()
      ..setQuery('only-in-one');
    workspace.schedule.drain();
    final before = workspace.container
        .read(terminalSessionsControllerProvider)
        .activeTab!
        .id;

    workspace.search.next();

    expect(
      workspace.container.read(terminalSessionsControllerProvider).activeTab!.id,
      before,
      reason: 'stepping moved nothing but the highlight',
    );
  });

  test('revealing a result jumps to the pane it came from', () {
    workspace.write(pane(2), 'only-in-two\r\n');

    workspace.search
      ..open(pane(0))
      ..toggleCrossPane()
      ..setQuery('only-in-two');
    workspace.schedule.drain();
    expect(workspace.state.currentPaneId, pane(2));

    workspace.search.revealCurrent();

    final sessions = workspace.container.read(
      terminalSessionsControllerProvider,
    );
    expect(sessions.activeTab!.id, workspace.tabOf(pane(2)));
    expect(sessions.activeTab!.focusedPaneId, pane(2));
    expect(highlightsIn(2), 1);
  });

  test('revealing with no match anywhere is a no-op', () {
    workspace.search
      ..open(pane(0))
      ..toggleCrossPane()
      ..setQuery('nothing-anywhere');
    workspace.schedule.drain();

    expect(workspace.search.revealCurrent, returnsNormally);
    expect(workspace.state.matchCount, 0);
  });

  test('turning cross-pane off drops the other panes results', () {
    workspace.write(pane(1), 'only-in-one\r\n');

    workspace.search
      ..open(pane(0))
      ..toggleCrossPane()
      ..setQuery('only-in-one');
    workspace.schedule.drain();
    expect(workspace.state.matchCount, 1);

    workspace.search.toggleCrossPane();
    workspace.schedule.drain();

    expect(workspace.state.crossPane, isFalse);
    expect(workspace.state.matchCount, 0);
    expect(workspace.state.panesSearched, 1);
    expect(highlightsIn(1), 0);
  });

  test('a detached session is searched too — it is still a live pane', () {
    // Closing a tab detaches its pane rather than killing it, which is the
    // whole point of keep-alive; a build still running in the background is
    // exactly the thing worth finding.
    giveShellHistory(workspace.sessions.instanceFor(pane(2))!);
    workspace.write(pane(2), 'in-the-background\r\n');
    workspace.sessions.closeTab(workspace.tabOf(pane(2)));
    expect(
      workspace.container.read(terminalSessionsControllerProvider).detached,
      hasLength(1),
      reason: 'the pane really was kept alive, not released',
    );

    workspace.search
      ..open(pane(0))
      ..toggleCrossPane()
      ..setQuery('in-the-background');
    workspace.schedule.drain();

    expect(workspace.state.matchCount, 1);
    expect(workspace.state.currentPaneId, pane(2));
  });

  test('regex composes with cross-pane', () {
    workspace.write(pane(1), 'exit code 7\r\n');

    workspace.search
      ..open(pane(0))
      ..toggleCrossPane()
      ..toggleRegex()
      ..setQuery(r'code \d');
    workspace.schedule.drain();

    expect(workspace.state.matchCount, 1);
    expect(workspace.state.currentPaneId, pane(1));
  });

  test('an invalid pattern arms no sweep at all', () {
    workspace.search
      ..open(pane(0))
      ..toggleCrossPane()
      ..toggleRegex()
      ..setQuery('a(');

    expect(workspace.state.patternError, isNotNull);
    expect(workspace.schedule.pendingCount, 0);
    expect(workspace.state.matchCount, 0);
  });
}
