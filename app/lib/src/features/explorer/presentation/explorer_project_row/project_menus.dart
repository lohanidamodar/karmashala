// A project row's menu entries.

part of '../explorer_project_row.dart';

/// One "New session with …" entry per agent installed here, when there are at
/// least two to choose from. A row whose agent the registry no longer knows
/// (a removed ACP agent's leftover) is not a choice, so it is not offered.
List<PopupMenuEntry<String>> newSessionWithItems(
  List<AgentInstallation> installations,
  AgentRegistry registry,
) {
  final known = [
    for (final installation in installations)
      if (registry.adapterFor(installation.agentId) != null) installation,
  ];
  if (known.length < 2) return const [];
  return [
    for (final installation in known)
      DesktopMenuItem(
        value: 'new-with:${installation.id}',
        label:
            'New session with '
            '${registry.displayNameFor(installation.agentId)}',
        icon: AppIcons.robot,
      ),
  ];
}

/// A project row's menu: open and new, the project, "More…", and the one
/// destructive verb last. Pure: every reading arrives as an argument.
List<PopupMenuEntry<String>> projectMenuItems({
  required Project project,
  required bool pinned,
  required String checkedSuffix,
  bool canOpenExternally = true,
  PopupMenuEntry<String>? select,
}) => [
  DesktopMenuItem(
    value: 'new-session',
    label: 'New session…',
    icon: AppIcons.chatCircleDots,
  ),
  DesktopMenuItem(
    value: 'terminal',
    label: 'Open terminal',
    icon: AppIcons.terminal,
  ),
  // An external editor here cannot open a folder on a server elsewhere.
  if (canOpenExternally)
    DesktopMenuItem(
      value: 'open-editor',
      label: 'Open in editor',
      icon: AppIcons.code,
    ),
  const DesktopMenuDivider(),
  DesktopMenuItem(
    value: 'edit',
    label: 'Edit project…',
    icon: AppIcons.pencilSimple,
    shortcut: 'F2',
  ),
  DesktopMenuItem(
    value: 'pin',
    label: pinned ? 'Unpin' : 'Pin to top',
    icon: pinned ? AppIcons.pushPinFill : AppIcons.pushPin,
  ),
  DesktopMenuItem(
    value: 'copy-path',
    label: 'Copy path',
    icon: AppIcons.copySimple,
  ),
  // The owner asked for it to stay in this popup, not behind More….
  DesktopMenuItem(
    value: 'refresh',
    label: 'Refresh CLI sessions$checkedSuffix',
    icon: AppIcons.arrowsClockwise,
  ),
  ?select,
  moreMenuItem(),
  const DesktopMenuDivider(),
  DesktopMenuItem(
    value: 'delete',
    label: 'Remove from workspace',
    icon: AppIcons.trash,
    destructive: true,
  ),
];

/// The project menu's "More…": the verbs reached for rarely. Pure.
List<PopupMenuEntry<String>> projectMoreMenuItems({
  required Project project,
  required List<Workspace> workspaces,
  required Map<String, int> workspaceCounts,
  required List<AgentInstallation> installations,
  required AgentRegistry registry,
  required bool canReveal,
  required String checkedSuffix,
  bool canOpenExternally = true,
}) => [
  // Offered only when there is a choice: with one installation the `+`
  // already uses it.
  ...newSessionWithItems(installations, registry),
  DesktopMenuItem(
    value: 'copy-cmd',
    label: 'Copy new-session command',
    icon: AppIcons.copy,
  ),
  const DesktopMenuDivider(),
  if (canOpenExternally)
    DesktopMenuItem(
      value: 'open-editor-subfolder',
      label: 'Open sub-folder in editor…',
      icon: AppIcons.folderOpen,
    ),
  // An SSH-owned row has no local spelling, so the entry would always fail.
  if (canReveal)
    DesktopMenuItem(
      value: 'reveal',
      label: 'Open in File Explorer',
      icon: AppIcons.folderOpen,
    ),
  // Which context this project is in, offered as the list it could be in
  // instead — one click to move, and *No context* never leaves the workspace.
  const DesktopMenuDivider(),
  for (final workspace in workspaces)
    DesktopMenuDetailItem(
      value: '$_contextAction${workspace.id}',
      label: workspace.name,
      detail: describeWorkspace(
        workspace,
        projectCount: workspaceCounts[workspace.id] ?? 0,
      ),
      detailMaxLines: 1,
      icon: AppIcons.folder,
      selected: project.workspaceId == workspace.id,
    ),
  if (project.workspaceId != null)
    DesktopMenuItem(
      value: '$_contextAction$_noContext',
      label: 'No context',
      icon: AppIcons.minusCircle,
    ),
  DesktopMenuItem(
    value: '$_contextAction$_newContext',
    label: workspaces.isEmpty
        ? 'Add to a new context…'
        : 'Move to a new context…',
    icon: AppIcons.folderPlus,
  ),
  const DesktopMenuDivider(),
  DesktopMenuItem(
    value: 'rescan',
    label: 'Rescan for repositories',
    icon: AppIcons.magnifyingGlass,
  ),
];
