import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/rows.dart';

import '../../environments/application/environments_controller.dart';
import '../../projects/application/projects_controller.dart';
import '../../sessions/presentation/new_session_dialog.dart';
import '../../sessions/presentation/session_destination_picker.dart';
import '../application/explorer_tree_nodes.dart';
import '../application/explorer_tree_state.dart';
import '../application/session_diff_stat.dart';
import 'explorer_project_row.dart';

/// **Sessions without a project**, every machine's on one row: its `+` starts
/// one, its menu removes a machine's Scratch with that machine's sessions.
/// Folding it is its only tap; what is under it is each machine's sessions.
class ExplorerNoProjectRow extends ConsumerWidget {
  const ExplorerNoProjectRow({required this.node, super.key});

  final NoProjectNode node;

  static const String _newAction = 'no-project:new';
  static const String _removePrefix = 'no-project:remove:';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ids = {for (final project in node.projects) project.id};
    final selected = ref.watch(selectedProjectIdProvider.select(ids.contains));
    var sessions = 0, running = 0, working = 0, needsAttention = 0;
    for (final project in node.projects) {
      final summary = ref.watch(projectSummaryProvider(project.id));
      sessions += summary.sessions;
      running += summary.running;
      working += summary.working;
      needsAttention += summary.needsAttention;
    }
    final machines = [
      for (final project in node.projects)
        ref.watch(environmentLabelForIdProvider(project.root.environmentId)),
    ];

    void toggle() => ref
        .read(explorerExpandedProjectsProvider.notifier)
        .toggle(kNoProjectNodeId);
    void start() => unawaited(
      NewSessionDialog.show(
        context,
        destination: const SessionDestination.scratch(),
      ),
    );

    List<PopupMenuEntry<String>> menuItems() => [
      DesktopMenuItem(
        value: _newAction,
        label: 'New session without a project…',
        icon: AppIcons.plus,
      ),
      const DesktopMenuDivider(),
      for (final (i, project) in node.projects.indexed)
        DesktopMenuItem(
          value: '$_removePrefix${project.id}',
          label: node.projects.length == 1
              ? 'Remove from workspace'
              : 'Remove the ones on ${machines[i]}',
          icon: AppIcons.trash,
          destructive: true,
        ),
    ];

    void onMenu(String action) {
      if (action == _newAction) return start();
      if (!action.startsWith(_removePrefix)) return;
      final id = action.substring(_removePrefix.length);
      final project = node.projects.where((p) => p.id == id).firstOrNull;
      if (project == null) return;
      ProjectRowActions(ref, context, project).onMenu('delete');
    }

    return ProjectLine(
      depth: 0,
      name: 'No project',
      where:
          'Sessions without a project, each in a folder of its own under '
          '~/karmashala/scratch on ${machines.join(', ')}',
      expanded: node.expanded,
      selected: selected,
      summary: ProjectSummary(
        sessions: sessions,
        running: running,
        working: working,
        needsAttention: needsAttention,
      ),
      onTap: toggle,
      onNewSession: start,
      menuItemsBuilder: menuItems,
      onMenu: onMenu,
    );
  }
}
