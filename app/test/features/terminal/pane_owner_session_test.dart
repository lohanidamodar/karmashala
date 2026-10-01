import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/terminal/application/pane_owner_session.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/geometry.dart';

/// Which session a document pane is working for: its own tab first, then the
/// nearest session tab leftward in its strip, then rightward — never another
/// group's.
void main() {
  TerminalTab tab(String id, String paneId) => TerminalTab(
    id: id,
    layout: PaneLayout.single(paneId),
    focusedPaneId: paneId,
  );

  final panes = PaneSessions.of({'agent-a': 'sA', 'agent-b': 'sB'});

  test('a document split beside an agent in one tab is that agent\'s', () {
    final shared = TerminalTab(
      id: 't1',
      layout: PaneLayout.single(
        'agent-a',
      ).split('agent-a', SplitAxis.horizontal, 'doc', 'split-1'),
      focusedPaneId: 'doc',
    );

    expect(
      sessionOwningPaneIn(panes, paneId: 'doc', tabs: [shared]),
      'sA',
      reason: 'the tab runs sA even with the document focused',
    );
  });

  test('the nearest session tab to the left in the strip wins', () {
    final tabs = [tab('t1', 'agent-a'), tab('t2', 'agent-b'), tab('t3', 'doc')];

    expect(
      sessionOwningPaneIn(
        panes,
        paneId: 'doc',
        tabs: tabs,
        groupTabIds: const ['t1', 't2', 't3'],
      ),
      'sB',
    );
  });

  test('with nothing to the left, the nearest to the right', () {
    final tabs = [tab('t1', 'doc'), tab('t2', 'shell'), tab('t3', 'agent-a')];

    expect(
      sessionOwningPaneIn(
        panes,
        paneId: 'doc',
        tabs: tabs,
        groupTabIds: const ['t1', 't2', 't3'],
      ),
      'sA',
    );
  });

  test('a session in another group is never the answer', () {
    final tabs = [tab('t1', 'agent-a'), tab('t2', 'doc')];

    expect(
      sessionOwningPaneIn(
        panes,
        paneId: 'doc',
        tabs: tabs,
        groupTabIds: const ['t2'],
      ),
      isNull,
    );
  });

  test('a pane no tab holds belongs to no session', () {
    expect(
      sessionOwningPaneIn(
        panes,
        paneId: 'gone',
        tabs: [tab('t1', 'agent-a')],
        groupTabIds: const ['t1'],
      ),
      isNull,
    );
  });
}
