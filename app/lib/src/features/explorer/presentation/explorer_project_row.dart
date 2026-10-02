import 'dart:async';

import '../../workspaces/data/workspace_data.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
import 'session_rows.dart';
import 'sidebar_chrome.dart';

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
        [
          ...projectMenuItems(
            project: project,
            pinned: pinned,
            workspaces: ref.read(workspacesControllerProvider),
            workspaceCounts: ref.read(workspaceProjectCountsProvider),
            installations: ref
                .read(agentInstallationsDataProvider)
                .getByEnvironment(project.root.environmentId),
            registry: ref.read(agentRegistryProvider),
            canReveal: ref
                .read(revealInFileManagerProvider)
                .canReveal(project.root),
            checkedSuffix: actions.checkedSuffix(),
            canOpenExternally: ref.read(capabilitiesProvider).readsServerDisk,
          ),
          const DesktopMenuDivider(),
          selectRowMenuItem(),
        ];
    Future<void> onMenu(String action) async {
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

/// **A project on one line** (spec §4, board A2): folder, name, the branch in
/// the muted mono hand, and the session count at the right — `+` and `⋮` in
/// its place on hover. 28px, the sidebar's row. What the second line would
/// have said is in the name's tooltip; a missing folder is the red folder and
/// that tooltip; what needs you is the amber badge beside the name, because
/// that is never left to a tooltip.
class ProjectLine extends StatelessWidget {
  const ProjectLine({
    required this.depth,
    required this.name,
    required this.where,
    required this.expanded,
    required this.selected,
    required this.summary,
    required this.onTap,
    required this.menuItemsBuilder,
    required this.onMenu,
    this.missing = false,
    this.pinned = false,
    this.onDisclosure,
    this.selecting = false,
    this.ticked = false,
    this.tickEnabled = true,
    this.tickDisabledTooltip,
    this.onNewSession,
    super.key,
  });

  final int depth;
  final String name;

  /// The machine and the whole path, for the name's tooltip.
  final String where;
  final bool expanded;
  final bool selected;
  final ProjectSummary summary;
  final VoidCallback onTap;
  final RowMenuItemBuilder menuItemsBuilder;
  final ValueChanged<String> onMenu;
  final bool missing;
  final bool pinned;
  final VoidCallback? onDisclosure;
  final bool selecting;
  final bool ticked;
  final bool tickEnabled;
  final String? tickDisabledTooltip;
  final VoidCallback? onNewSession;

  /// The most of the line a branch name may take before it is ellipsised: the
  /// name is what tells two projects apart, so the branch gives way first.
  static const branchMax = 96.0;

  @override
  Widget build(BuildContext context) => ExplorerRow(
    kind: ExplorerRowKind.project,
    minHeight: Sidebar.rowHeight,
    expanded: expanded,
    depth: depth,
    selected: selected,
    onTap: onTap,
    menuItemsBuilder: menuItemsBuilder,
    onMenu: onMenu,
    builder: (context) {
      final theme = Theme.of(context);
      final scheme = theme.colorScheme;
      final density = UiDensity.of(context);
      final scaler = MediaQuery.textScalerOf(context);
      final ahead = summary.commitsAhead ?? 0;
      final branch = missing ? null : summary.branch;
      final count = [?summary.label, ?summary.attentionLabel].join(' · ');
      return Row(
        children: [
          ExplorerRowLead(
            expanded: expanded,
            onDisclosure: onDisclosure,
            tick: selecting
                ? ExplorerRowTick(
                    value: ticked,
                    semanticLabel: 'Select "$name"',
                    onChanged: tickEnabled ? onTap : null,
                    disabledTooltip: tickDisabledTooltip,
                  )
                : null,
            glyph: Icon(
              expanded ? AppIcons.folderOpen : AppIcons.folder,
              size: ExplorerRow.glyphSize,
              color: missing ? scheme.error : scheme.onSurfaceVariant,
            ),
          ),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Tooltip(
                    message: missing ? 'Folder not found\n$where' : where,
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: density.rowTitle(
                        theme,
                        strong: summary.needsAttention > 0,
                      ),
                    ),
                  ),
                ),
                if (pinned) ...[
                  SizedBox(width: density.glyphGap),
                  Tooltip(
                    message: 'Pinned to top',
                    child: Icon(
                      AppIcons.pushPinFill,
                      size: density.iconSmall,
                      color: scheme.tertiary,
                    ),
                  ),
                ],
                if (summary.needsAttention > 0)
                  ProjectStateBadge.needsYou(summary),
                if (branch != null) ...[
                  const SizedBox(width: Insets.sm),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: scaler.scale(branchMax),
                    ),
                    child: Text(
                      ahead > 0 ? '$branch ↑$ahead' : branch,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: MonoStyles.small.copyWith(color: scheme.outline),
                    ),
                  ),
                ],
              ],
            ),
          ),
          SizedBox(
            width: ExplorerRow.trailingWidthOf(context),
            child: ExplorerRowTrailing(
              meta: summary.sessions == 0
                  ? null
                  : ExplorerRowMeta(
                      '${summary.sessions}',
                      tooltip: count,
                      color: scheme.outline,
                    ),
              action: onNewSession == null
                  ? null
                  : ExplorerRowAction(
                      tooltip: 'Start a session here with the default agent',
                      icon: AppIcons.plus,
                      onPressed: onNewSession,
                    ),
              menu: RowMenuButton(
                tooltip: 'Project actions',
                itemBuilder: menuItemsBuilder,
                onSelected: onMenu,
              ),
            ),
          ),
        ],
      );
    },
  );
}

/// A project row's menu. Pure: every reading arrives as an argument.
List<PopupMenuEntry<String>> projectMenuItems({
  required Project project,
  required bool pinned,
  required List<Workspace> workspaces,
  required Map<String, int> workspaceCounts,
  required List<AgentInstallation> installations,
  required AgentRegistry registry,
  required bool canReveal,
  required String checkedSuffix,
  bool canOpenExternally = true,
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
  // Offered only when there is a choice: with one installation the `+`
  // already uses it.
  if (installations.length >= 2)
    for (final installation in installations)
      DesktopMenuItem(
        value: 'new-with:${installation.id}',
        label:
            'New session with '
            '${registry.displayNameFor(installation.agentId)}',
        icon: AppIcons.robot,
      ),
  DesktopMenuItem(
    value: 'copy-cmd',
    label: 'Copy new-session command',
    icon: AppIcons.copy,
  ),
  // An external editor here cannot open a folder on a server elsewhere.
  if (canOpenExternally) ...[
    const DesktopMenuDivider(),
    DesktopMenuItem(
      value: 'open-editor',
      label: 'Open in editor',
      icon: AppIcons.code,
    ),
    DesktopMenuItem(
      value: 'open-editor-subfolder',
      label: 'Open sub-folder in editor…',
      icon: AppIcons.folderOpen,
    ),
  ],
  const DesktopMenuDivider(),
  // An SSH-owned row has no local spelling, so the entry would always fail.
  if (canReveal)
    DesktopMenuItem(
      value: 'reveal',
      label: 'Open in File Explorer',
      icon: AppIcons.folderOpen,
    ),
  DesktopMenuItem(
    value: 'copy-path',
    label: 'Copy path',
    icon: AppIcons.copySimple,
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
    value: 'refresh',
    label: 'Refresh CLI sessions$checkedSuffix',
    icon: AppIcons.arrowsClockwise,
  ),
  DesktopMenuItem(
    value: 'rescan',
    label: 'Rescan for repositories',
    icon: AppIcons.magnifyingGlass,
  ),
  const DesktopMenuDivider(),
  DesktopMenuItem(
    value: 'delete',
    label: 'Remove from workspace',
    icon: AppIcons.trash,
    destructive: true,
  ),
];

/// What a project row's taps and menu do. Holds no state of its own: the
/// expansion lives in [explorerExpandedProjectsProvider].
class ProjectRowActions {
  ProjectRowActions(this.ref, this.context, this.project);

  final WidgetRef ref;
  final BuildContext context;
  final Project project;

  void _say(String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void toggle() {
    ref.read(explorerExpandedProjectsProvider.notifier).toggle(project.id);
    // A deliberate pick outranks wherever the pane on screen has wandered to,
    // until you move panes yourself.
    ref.read(explorerFollowHoldProvider.notifier).hold();
    ref.read(selectedProjectIdProvider.notifier).select(project.id);
    // Single-repository projects select that repository so "New session" and
    // the detail view have a working context immediately.
    final repos = ref.read(workspaceDataProvider).repositoriesOf(project.id);
    if (repos.length == 1) {
      ref.read(selectedRepositoryIdProvider.notifier).select(repos.first.id);
    }
    // Nothing is scanned here: `explorer_expand_scan_cost_test.dart` pins it.
  }

  void togglePin() => ref
      .read(settingsControllerProvider.notifier)
      .togglePinnedProject(project.id);

  /// " · checked 3m ago", or " · never checked" when nothing has read the
  /// stores for this project yet.
  String checkedSuffix() {
    final at = ref.read(cliSessionsCheckedProvider).forProject(project.id);
    if (at == null) return ' · never checked';
    final now = ref.read(clockProvider).nowUtc();
    return ' · checked ${describeAge(now.difference(at))}';
  }

  /// Where a session started *at the project* runs — the checkout the project
  /// chose, else the first one the picker would offer, so the `+` and the
  /// dialog cannot pick different clones.
  Repository? _defaultCheckout() => projectDefaultCheckout(
    defaultRepositoryId: project.defaultRepositoryId,
    offered: ref.read(checkoutsInProjectProvider(project.id)),
    all: ref.read(workspaceDataProvider).repositoriesOf(project.id),
  );

  /// [_defaultCheckout], falling back to the project's own folder for a project
  /// that has no checkout recorded at all — a folder is enough to run in. Null
  /// only once the real reason has been said.
  Future<Repository?> _runLocation() async {
    final chosen = _defaultCheckout();
    if (chosen != null) return chosen;
    try {
      return await ref
          .read(projectsControllerProvider.notifier)
          .ensureRunLocation(project.id);
    } on StateError catch (error) {
      _say(error.message);
      return null;
    }
  }

  Future<void> _startSession({
    required Repository repository,
    AgentInstallation? installation,
  }) async {
    final result = await ref
        .read(explorerActionsProvider)
        .startSession(repository: repository, installation: installation);
    final message = result.message;
    if (message != null) _say(message);
  }

  /// The `+`: starts a session with [SessionDefaults] and no dialog — unless a
  /// piece is missing, when the dialog opens to name it.
  Future<void> startWithDefaults() async {
    final repository = await _runLocation();
    // Null only once `_runLocation` has said why; opening the dialog would ask
    // the same question again and answer it with the same sentence.
    if (repository == null) return;
    final defaults = ref.read(sessionDefaultsProvider).forCheckout(repository);
    if (!defaults.isComplete) {
      await newSessionDialog(repository: repository);
      return;
    }
    // The card the session appears on has to be on screen: a start nobody can
    // see is indistinguishable from a dead click.
    if (ref.read(selectedProjectIdProvider) != project.id) {
      ref.read(selectedProjectIdProvider.notifier).select(project.id);
    }
    ref.read(explorerExpandedProjectsProvider.notifier).open(project.id);
    await _startSession(
      repository: repository,
      installation: defaults.installation,
    );
  }

  Future<void> newSessionDialog({Repository? repository}) async {
    ref.read(selectedProjectIdProvider.notifier).select(project.id);
    ref.read(explorerExpandedProjectsProvider.notifier).open(project.id);
    final repo = repository ?? await _runLocation();
    // The dialog opens on the current selection, so opening it with nowhere to
    // run would point it at whichever other project was last selected.
    // `_runLocation` has already said why there is nowhere.
    if (repo == null || !context.mounted) return;
    ref.read(selectedRepositoryIdProvider.notifier).select(repo.id);
    unawaited(NewSessionDialog.show(context));
  }

  void openTerminal() {
    final env = ref
        .read(environmentsDataProvider)
        .getById(project.environmentId);
    final controller = ref.read(terminalSessionsControllerProvider.notifier);
    final sshHostId = env?.sshHostId;
    final TerminalProfile profile;
    if (sshHostId != null) {
      profile = TerminalProfile.ssh(sshHostId, hostName: env?.name);
    } else if (env?.kind == EnvironmentKind.wsl) {
      final distro = env?.wslDistribution ?? env?.name ?? '';
      profile = TerminalProfile(
        id: TerminalProfile.wslId(distro),
        label: '$distro (WSL)',
        shell: TerminalShell.wsl,
        wslDistribution: distro,
      );
    } else {
      profile = TerminalProfile.powerShell;
    }
    controller.openTab(profile, workingDirectory: project.root.path);
    controller.showTerminalHere();
  }

  Future<void> _syncSessions() async {
    try {
      final result = await ref
          .read(projectsControllerProvider.notifier)
          .syncSessions(project.id);
      _say(
        result.sessions == 0
            ? 'Sessions are up to date.'
            : 'Added ${result.sessions} CLI session${result.sessions == 1 ? '' : 's'}.',
      );
    } catch (error) {
      _say('Could not refresh sessions: $error');
    }
  }

  /// Re-runs discovery over the project's folder, which is what turns a "not
  /// scanned yet" row into a real repository row.
  Future<void> _rescan() async {
    try {
      final added = await ref
          .read(projectsControllerProvider.notifier)
          .rediscover(project.id);
      _say(
        added.isEmpty
            ? 'No new repositories found in ${project.name}.'
            : 'Found ${added.length} '
                  'repositor${added.length == 1 ? 'y' : 'ies'}.',
      );
    } catch (error) {
      _say(error is StateError ? error.message : 'Could not rescan: $error');
    }
  }

  /// [RevealInFileManager.reveal] reports failure as a [RevealOutcome].
  Future<void> _reveal() async {
    final outcome = await ref
        .read(revealInFileManagerProvider)
        .reveal(project.root);
    if (!outcome.ok) _say(outcome.error!);
  }

  Future<void> _copyPath() async {
    await Clipboard.setData(ClipboardData(text: project.root.path));
    _say('Path copied to clipboard');
  }

  /// With [chooseSubfolder], a picker rooted at the project chooses a
  /// sub-folder to open instead of the project root.
  Future<void> _openInEditor({bool chooseSubfolder = false}) async {
    final actions = ref.read(editorActionsProvider);
    String? subPath;
    if (chooseSubfolder) {
      final picked = await pickOneDirectory(
        context: context,
        what: 'a folder of ${project.name} to open',
        startNear: project.root.path,
        confirmButtonText: 'Open in editor',
      );
      if (picked == null) return;
      subPath = picked;
    }
    try {
      await actions.openProject(project.id, subPath: subPath);
      _say('Opening in editor…');
    } catch (e) {
      _say(e is StateError ? e.message : '$e');
    }
  }

  Future<void> _confirmDelete() async {
    final deleteCliSessions = await showDialog<bool>(
      context: context,
      builder: (context) => _RemoveProjectDialog(name: project.name),
    );
    if (deleteCliSessions == null) return;
    await ref
        .read(projectsControllerProvider.notifier)
        .deleteProject(project.id, deleteCliSessions: deleteCliSessions);
  }

  /// Files the project where the menu said, and says what happened.
  Future<void> _applyContextAction(String action) async {
    final target = action.substring(_contextAction.length);
    final controller = ref.read(workspacesControllerProvider.notifier);
    if (target == _noContext) {
      await controller.assign(project.id, null);
      // Named in full, because the menu's other leaving verb deletes the
      // project and this one must not be mistaken for it.
      _say('"${project.name}" is no longer in a context. It is still here.');
      return;
    }
    if (target == _newContext) {
      final created = await NewContextDialog.show(
        context,
        forProjectNamed: project.name,
      );
      if (created == null) return;
      await controller.assign(project.id, created.id);
      _say('Moved "${project.name}" to ${created.name}.');
      return;
    }
    if (project.workspaceId == target) return;
    await controller.assign(project.id, target);
    final name = ref
        .read(workspacesControllerProvider)
        .where((w) => w.id == target)
        .map((w) => w.name)
        .firstOrNull;
    if (name != null) _say('Moved "${project.name}" to $name.');
  }

  void onMenu(String action) {
    if (action.startsWith('new-with:')) {
      final id = action.substring('new-with:'.length);
      final installation = ref
          .read(agentInstallationsDataProvider)
          .getByEnvironment(project.root.environmentId)
          .where((installation) => installation.id == id)
          .firstOrNull;
      if (installation == null) return;
      unawaited(
        _runLocation().then((repo) {
          if (repo != null) {
            _startSession(repository: repo, installation: installation);
          }
        }),
      );
      return;
    }
    if (action.startsWith(_contextAction)) {
      _applyContextAction(action);
      return;
    }
    switch (action) {
      case 'new-session':
        newSessionDialog();
      case 'terminal':
        openTerminal();
      case 'copy-cmd':
        copyCommandToClipboard(
          context,
          () => ref
              .read(sessionActionsProvider)
              .newSessionShellCommand(project.id),
        );
      case 'open-editor':
        _openInEditor();
      case 'open-editor-subfolder':
        _openInEditor(chooseSubfolder: true);
      case 'reveal':
        _reveal();
      case 'copy-path':
        _copyPath();
      case 'edit':
        EditProjectDialog.show(context, project);
      case 'pin':
        togglePin();
      case 'refresh':
        _syncSessions();
      case 'rescan':
        _rescan();
      case 'delete':
        _confirmDelete();
    }
  }
}

/// Asks before removing a project. Pops null for cancel, otherwise whether to
/// delete the CLI's session files too.
class _RemoveProjectDialog extends StatefulWidget {
  const _RemoveProjectDialog({required this.name});

  final String name;

  @override
  State<_RemoveProjectDialog> createState() => _RemoveProjectDialogState();
}

class _RemoveProjectDialogState extends State<_RemoveProjectDialog> {
  bool _deleteCliSessions = false;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const DesktopDialogTitle(
      icon: AppIcons.trash,
      title: 'Remove project?',
      subtitle: 'This only changes the Karmashala workspace.',
    ),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Removes "${widget.name}" and all its sessions from the workspace.',
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: _deleteCliSessions,
          onChanged: (v) => setState(() => _deleteCliSessions = v ?? false),
          title: const Text('Also delete session files on disk'),
          subtitle: const Text(
            "Permanently removes this project's Claude/Codex session "
            'history from the CLI store. Otherwise, files on disk are '
            'left untouched.',
          ),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      DestructiveButton(
        onPressed: () => Navigator.of(context).pop(_deleteCliSessions),
        child: const Text('Delete'),
      ),
    ],
  );
}
