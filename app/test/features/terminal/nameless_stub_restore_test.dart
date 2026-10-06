import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_terminal_runtime/persistence.dart';

import 'fake_instance.dart';

/// A saved pane with no process, no session and no title — a dead tab named
/// only by its id — is dropped on restore, so old layouts holding them heal.
void main() {
  StoredTerminalPane pane(
    String id,
    String tabId, {
    required String title,
    bool wasLive = false,
  }) => StoredTerminalPane(
    id: id,
    tabId: tabId,
    profileId: 'powershell',
    title: title,
    workingDirectory: null,
    scrollback: '',
    wasLive: wasLive,
  );

  StoredTerminalTab tab(String id, List<StoredTerminalPane> panes) =>
      StoredTerminalTab(
        id: id,
        layout: panes.length == 1
            ? PaneLayout.single(panes.single.id)
            : PaneLayout.single(panes.first.id).split(
                panes.first.id,
                SplitAxis.horizontal,
                panes.last.id,
                'split',
              ),
        focusedPaneId: panes.first.id,
        panes: panes,
      );

  test('a pane titled only by its id, or not at all, is not restored; '
      'a named one beside it is', () {
    const stub = '0f1e2d3c-0000-4000-8000-000000000001';
    final db = TerminalLayoutStore.memory();
    addTearDown(db.close);
    TerminalLayoutDao(db).saveLayout([
      tab('t1', [pane(stub, 't1', title: stub)]),
      tab('t2', [pane('blank', 't2', title: '  ')]),
      tab('t3', [
        pane('shell', 't3', title: 'PowerShell'),
        pane('other-stub', 't3', title: 'other-stub'),
      ]),
      tab('t4', [
        pane('was-running', 't4', title: 'was-running', wasLive: true),
      ]),
    ], activeTabId: 't3');

    final container = fakeTerminalContainer(layoutStore: db);
    addTearDown(container.dispose);
    final tabs = container.read(terminalSessionsControllerProvider).tabs;

    expect([for (final t in tabs) t.id], ['t3', 't4']);
    expect(tabs.first.layout.panes, ['shell']);
  });
}
