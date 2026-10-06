import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_project_row.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_selection_actions.dart';
import 'package:karmashala/src/features/explorer/presentation/more_menu.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:karmashala_ui/menus.dart';

import '../../support/fixtures.dart';

/// The project menu, reorganised: the frequent verbs in sections, the rare
/// ones behind "More…", destructive last — and nothing lost on the way.
void main() {
  final installations = [
    agentInstallation(id: 'a', agentId: AgentIds.claudeCode),
    agentInstallation(id: 'b', agentId: AgentIds.codex, path: r'C:\codex.exe'),
  ];
  final contexts = [
    Workspace(id: 'w1', name: 'Client work', createdAt: testTime),
  ];

  List<PopupMenuEntry<String>> main() => projectMenuItems(
    project: project(),
    pinned: false,
    checkedSuffix: ' · checked just now',
    select: selectRowMenuItem(),
  );

  List<PopupMenuEntry<String>> more() => projectMoreMenuItems(
    project: project(),
    workspaces: contexts,
    workspaceCounts: const {'w1': 3},
    installations: installations,
    registry: AgentRegistry.builtIn,
    canReveal: true,
    checkedSuffix: ' · checked just now',
  );

  List<String> labelsOf(List<PopupMenuEntry<String>> items) => [
    for (final item in items)
      switch (item) {
        DesktopMenuItem<String>(:final label) => label,
        DesktopMenuDetailItem<String>(:final child) =>
          (child! as DesktopMenuDetailRow).label,
        _ => '---',
      },
  ];

  Set<String> valuesOf(List<PopupMenuEntry<String>> items) => {
    for (final item in items)
      if (item is PopupMenuItem<String>) ?item.value,
  };

  test('the menu: open and new, the project, More…, then danger', () {
    expect(labelsOf(main()), [
      'New session…',
      'Open terminal',
      'Open in editor',
      '---',
      'Edit project…',
      'Pin to top',
      'Copy path',
      'Refresh CLI sessions · checked just now',
      'Select',
      'More…',
      '---',
      'Remove from workspace',
    ]);
  });

  test('More… holds the rare verbs', () {
    expect(labelsOf(more()), [
      'New session with Claude Code',
      'New session with Codex CLI',
      'Copy new-session command',
      '---',
      'Open sub-folder in editor…',
      'Open in File Explorer',
      '---',
      'Client work',
      'Move to a new context…',
      '---',
      'Rescan for repositories',
    ]);
  });

  test('every verb the old menu had is still offered by one of the two', () {
    final offered = {...valuesOf(main()), ...valuesOf(more())};
    expect(offered, containsAll(<String>[
      'new-session',
      'terminal',
      'new-with:a',
      'new-with:b',
      'copy-cmd',
      'open-editor',
      'open-editor-subfolder',
      'reveal',
      'copy-path',
      'context:w1',
      'context:new',
      'edit',
      'pin',
      'refresh',
      'rescan',
      'delete',
      'select',
      kMoreMenuValue,
    ]));
  });
}
