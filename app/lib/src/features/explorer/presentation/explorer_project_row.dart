import 'dart:async';

import '../../workspaces/data/workspace_data.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show DataRefused;
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_session/resume.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/picking.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/shell/reveal_in_file_manager.dart';
import '../../../core/capabilities/capabilities.dart';
import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import '../../editor/application/code_editor_providers.dart';
import '../../git/application/changes_providers.dart';
import '../../environments/application/environment_providers.dart';
import '../../projects/application/projects_controller.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import '../../projects/presentation/edit_project_dialog.dart';
import '../../sessions/application/session_actions.dart';
import '../../sessions/application/session_defaults.dart';
import '../../sessions/presentation/new_session_dialog.dart';
import '../../settings/application/settings_controller.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../../workspaces/application/workspaces_controller.dart';
import '../../workspaces/presentation/new_context_dialog.dart';
import '../application/checkout_default.dart';
import '../application/checkout_picker.dart';
import '../application/explorer_actions.dart';
import '../application/explorer_tree_state.dart';
import '../application/project_head.dart';
import '../application/session_diff_stat.dart';
import '../application/session_selection.dart';
import '../application/where_you_are.dart';
import 'explorer_selection_actions.dart';
import 'more_menu.dart';
import 'session_rows.dart';
import 'sidebar_chrome.dart';

part 'explorer_project_row/project_line.dart';
part 'explorer_project_row/project_menus.dart';
part 'explorer_project_row/project_row_actions.dart';

/// Prefix on a "put this project in a context" menu value, so one `startsWith`
/// tells it from the row's other verbs — the shape `new-with:` uses for agents.
const _contextAction = 'context:';

/// The two choices in that list that are not a context id. Neither can collide
/// with one: an id is generated, and these are spelled without the prefix.
const _noContext = 'none';
const _newContext = 'new';

/// One project in the Explorer tree. It watches only its own facts, so a
/// session starting under it repaints this card and not the tree around it.
class ExplorerProjectRow extends ConsumerWidget {
  const ExplorerProjectRow({
    required this.project,
    required this.depth,
    required this.expanded,
    this.pathCandidates,
    this.environmentBadge,
    this.environmentLabel,
    this.environmentIcon,
    this.anchorKey,
    super.key,
  });

  final Project project;
  final int depth;
  final bool expanded;

  /// From the tree's node, which cut the path and named the machine once.
  final List<String>? pathCandidates;
  final String? environmentBadge;

  /// The machine, named on the row — only where the scope bar does not say it.
  final String? environmentLabel;
  final IconData? environmentIcon;

  /// Held while this is the selected project, so the panel can finish a
  /// reveal exactly rather than at its estimate.
  final Key? anchorKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(
      selectedProjectIdProvider.select((id) => id == project.id),
    );
    final pinned = ref.watch(
      settingsControllerProvider.select((s) => s.isPinned(project.id)),
    );
    // `.value`, not `asData`: a re-ask carries the last answer, so the mark
    // does not blink when the window comes back to the front.
    final missing =
        ref.watch(projectPathMissingProvider(project)).value ?? false;
    // Sessions come from the database; changed files are whatever the
    // per-checkout providers already answered, so no header starts a git wave.
    final summary = ref.watch(projectSummaryProvider(project.id));
    final detail = ref.watch(
      settingsControllerProvider.select((s) => s.explorerProjectDetails),
    );
    // The branch off the repository's own `HEAD` — a file read, for a row that
    // is built: both the one-line row and the second line name the branch.
    // `.value`, not `asData`: a re-read carries the last answer, so the branch
    // does not blink.
    final head = ref.watch(
      projectHeadBranchProvider(project.id).select((head) => head.value),
    );
    final actions = ProjectRowActions(ref, context, project);
    // Each its own `.select`, so ticking one project moves that row alone.
    final selecting = ref.watch(
      sessionSelectionProvider.select((s) => s.active),
    );
    final ticked = ref.watch(
      sessionSelectionProvider.select((s) => s.contains(project.id)),
    );
    final tickEnabled = ref.watch(
      sessionSelectionProvider.select((s) => s.canTick(SelectionKind.projects)),
    );

    // A borrowed reading wins: it also knows `↑n` and what changed.
    final known = summary.withBranchFallback(head);
    void onTap() {
      if (!handleSelectableClick(
        ref,
        id: project.id,
        kind: SelectionKind.projects,
      )) {
        actions.toggle();
      }
    }

    // While a click means *tick*, the caret alone still folds.
    final VoidCallback? onDisclosure = selecting
        ? () => ref
              .read(explorerExpandedProjectsProvider.notifier)
              .toggle(project.id)
        : null;
    // Built when the menu opens, so the readings behind it are current.
    List<PopupMenuEntry<String>> menuItems() =>
        selectionRowMenu(ref, context, project.id) ??
        projectMenuItems(
          project: project,
          pinned: pinned,
          checkedSuffix: actions.checkedSuffix(),
          canOpenExternally: ref.read(capabilitiesProvider).readsServerDisk,
          select: selectRowMenuItem(),
        );
    List<PopupMenuEntry<String>> moreItems() => projectMoreMenuItems(
      project: project,
      workspaces: ref.read(workspacesControllerProvider),
      workspaceCounts: ref.read(workspaceProjectCountsProvider),
      installations: ref
          .read(agentInstallationsDataProvider)
          .getByEnvironment(project.root.environmentId),
      registry: ref.read(agentRegistryProvider),
      canReveal: ref.read(revealInFileManagerProvider).canReveal(project.root),
      checkedSuffix: actions.checkedSuffix(),
      canOpenExternally: ref.read(capabilitiesProvider).readsServerDisk,
    );
    Future<void> onMenu(String action) async {
      if (action == kMoreMenuValue) {
        final picked = await showMoreMenu(context, moreItems());
        if (picked == null || !context.mounted) return;
        action = picked;
      }
      if (!context.mounted) return;
      if (runSelectionRowAction(
        ref,
        context,
        action,
        id: project.id,
        kind: SelectionKind.projects,
      )) {
        return;
      }
      actions.onMenu(action);
    }

    // The sidebar's one-line row (board A2) under a pointer, unless the user
    // asked for project details — then the card with its second line.
    if (!detail && !UiDensity.of(context).isTouch) {
      return KeyedSubtree(
        key: anchorKey,
        child: ProjectLine(
          depth: depth,
          name: project.name,
          where: [
            ?(environmentBadge ?? environmentLabel),
            project.root.path,
          ].where((part) => part.isNotEmpty).join('\n'),
          expanded: expanded,
          selected: selected,
          missing: missing,
          pinned: pinned,
          summary: known,
          onTap: onTap,
          onDisclosure: onDisclosure,
          selecting: selecting,
          ticked: ticked,
          tickEnabled: tickEnabled,
          tickDisabledTooltip: SelectionKind.sessions.holdsLabel,
          onNewSession: actions.startWithDefaults,
          menuItemsBuilder: menuItems,
          onMenu: onMenu,
        ),
      );
    }

    return KeyedSubtree(
      key: anchorKey,
      child: ProjectCard(
        depth: depth,
        name: project.name,
        path: project.root.path,
        expanded: expanded,
        selected: selected,
        missing: missing,
        pinned: pinned,
        environmentBadge: environmentBadge,
        environmentLabel: environmentLabel,
        environmentIcon: environmentIcon,
        pathCandidates: pathCandidates,
        detail: detail,
        summary: known,
        onTap: onTap,
        selecting: selecting,
        ticked: ticked,
        tickEnabled: tickEnabled,
        tickDisabledTooltip: SelectionKind.sessions.holdsLabel,
        onDisclosure: onDisclosure,
        // Starts one; the menu is where the dialog lives.
        onNewSession: actions.startWithDefaults,
        onTogglePin: actions.togglePin,
        menuItemsBuilder: menuItems,
        onMenu: onMenu,
      ),
    );
  }
}
