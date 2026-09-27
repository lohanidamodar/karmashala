import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../environments/application/environment_providers.dart';
import '../../settings/application/settings_controller.dart';
import '../../ssh/data/ssh_hosts_data.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../../workspaces/application/workspaces_controller.dart';
import '../application/environment_terminals_providers.dart';
import '../application/explorer_tree_nodes.dart';
import '../application/explorer_tree_provider.dart';
import 'environment_rows.dart';
import 'explorer_context_actions.dart';
import 'explorer_keyboard.dart';
import 'explorer_project_row.dart';
import 'explorer_sections_view.dart';
import 'session_rows.dart';

/// One Explorer row for [node]. Each kind is its own widget so that the
/// readings a row needs are watched by that row alone.
class ExplorerTreeRow extends StatelessWidget {
  const ExplorerTreeRow({
    required this.node,
    this.anchorKey,
    this.first = false,
    super.key,
  });

  final ExplorerNode node;

  /// Handed to the selected project's row — see [ExplorerProjectRow.anchorKey].
  final Key? anchorKey;

  /// The list's first row, and the pinned copy: a header there keeps no gap
  /// above its band.
  final bool first;

  @override
  Widget build(BuildContext context) => switch (node) {
    final ContextHeaderNode node => ExplorerContextHeader(
      node: node,
      spaceAbove: !first,
    ),
    final TerminalsHeaderNode node => ExplorerTerminalsHeader(
      node: node,
      spaceAbove: !first,
    ),
    final SectionHeaderNode node => ExplorerSectionHeader(
      section: node.section,
      count: node.count,
      spaceAbove: !first,
    ),
    final ProjectNode node => ExplorerProjectRow(
      project: node.project,
      depth: node.depth,
      expanded: node.expanded,
      pathCandidates: node.pathCandidates,
      environmentBadge: node.environmentBadge,
      environmentLabel: node.environmentLabel,
      environmentIcon: node.environmentLabel == null
          ? null
          : environmentGlyph(node.environmentKind),
      anchorKey: anchorKey,
    ),
    final SessionRowNode node => ExplorerNativeSessionRow(node: node),
    final ImportedRowNode node => ImportedSessionRow(
      session: node.session,
      depth: node.depth,
      subPath: node.subPath,
      pinned: node.pinned,
    ),
    final TerminalRowNode node => ExplorerTerminalRow(node: node),
    final HintNode node => ExplorerTreeHint(
      depth: node.depth,
      message: node.message,
    ),
  };
}

/// A context's label over its projects — or *No context*, over the rest.
class ExplorerContextHeader extends ConsumerWidget {
  const ExplorerContextHeader({
    required this.node,
    this.spaceAbove = true,
    super.key,
  });

  final ContextHeaderNode node;
  final bool spaceAbove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workspace = node.workspace;
    return ExplorerGroupHeader(
      expanded: node.expanded,
      label: node.label,
      hue: ContextHue.tryParse(workspace?.color),
      spaceAbove: spaceAbove,
      trailingText: '${node.projectCount}',
      trailingWords: projectCountWords(node.projectCount),
      tooltip: workspace?.description,
      onTap: () => ref
          .read(settingsControllerProvider.notifier)
          .toggleExplorerNodeCollapsed(node.id),
      menuLabel: 'Context actions',
      // Built when the menu opens, so "show only" reads the scope as it is.
      menuItemsBuilder: () => contextMenuItems(
        workspace: workspace,
        scope: ref.read(workspaceScopeProvider),
      ),
      onMenu: (action) => runContextAction(ref, context, action, workspace),
    );
  }
}

/// `Terminals`, for one machine. It carries what the machine's own row used
/// to: the `+` that opens a shell there, and the word that it has gone.
class ExplorerTerminalsHeader extends ConsumerWidget {
  const ExplorerTerminalsHeader({
    required this.node,
    this.spaceAbove = true,
    super.key,
  });

  final TerminalsHeaderNode node;
  final bool spaceAbove;

  static const _open = 'open';
  static const _refresh = 'refresh';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Not offered for a machine whose row is gone: we cannot say what it is,
    // and the fallback would quietly open a shell on this one.
    final known = node.environment != null;
    return ExplorerGroupHeader(
      expanded: node.expanded,
      label: node.label,
      spaceAbove: spaceAbove,
      trailingText: node.count == null ? null : '${node.count}',
      trailingWords: node.count == null ? null : '${node.count} running',
      detail: node.detail,
      tooltip: known ? null : 'This environment is no longer in the workspace.',
      onTap: () => toggleExplorerTerminals(ref, node.environmentId),
      action: known
          ? ExplorerRowAction(
              tooltip: 'Open a terminal on ${node.environmentLabel}',
              icon: AppIcons.plus,
              onPressed: () => openTerminalOn(ref, node.environment!),
            )
          : null,
      menuLabel: 'Terminal actions',
      menuItemsBuilder: !known && !node.expanded
          ? null
          : () => [
              if (known)
                DesktopMenuItem(
                  value: _open,
                  label: 'Open a terminal on ${node.environmentLabel}',
                  icon: AppIcons.terminal,
                ),
              if (node.expanded)
                DesktopMenuItem(
                  value: _refresh,
                  label: 'Ask again',
                  icon: AppIcons.arrowsClockwise,
                ),
            ],
      onMenu: (action) {
        switch (action) {
          case _open:
            openTerminalOn(ref, node.environment!);
          case _refresh:
            ref
                .read(environmentTerminalsProvider(node.environmentId).notifier)
                .refresh();
        }
      },
    );
  }
}

/// Opens a shell on [environment], in the terminal pane.
void openTerminalOn(WidgetRef ref, ExecutionEnvironment environment) {
  final controller = ref.read(terminalSessionsControllerProvider.notifier);
  final distro = environment.wslDistribution ?? environment.name;
  controller.openTab(switch (environment.kind) {
    EnvironmentKind.ssh when environment.sshHostId != null =>
      TerminalProfile.ssh(environment.sshHostId!, hostName: environment.name),
    EnvironmentKind.wsl => TerminalProfile(
      id: TerminalProfile.wslId(distro),
      label: '$distro (WSL)',
      shell: TerminalShell.wsl,
      wslDistribution: distro,
    ),
    _ => TerminalProfile.powerShell,
  });
  controller.showTerminalHere();
}

/// A native session. Draws the session as it is *now*, selected out of its
/// project's sessions, so its own status tick rebuilds this row alone.
class ExplorerNativeSessionRow extends ConsumerWidget {
  const ExplorerNativeSessionRow({required this.node, super.key});

  final SessionRowNode node;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session =
        ref.watch(
          explorerProjectNativeSessionsProvider(
            node.projectId,
          ).select((sessions) => sessions[node.session.id]),
        ) ??
        node.session;
    return NativeSessionRow(
      session: session,
      depth: node.depth,
      subPath: node.subPath,
      pinned: node.pinned,
      link: node.link,
      parentTitle: node.parentTitle,
      lineageBroken: node.lineageBroken,
    );
  }
}

/// One terminal under a machine's `Terminals`.
class ExplorerTerminalRow extends ConsumerWidget {
  const ExplorerTerminalRow({required this.node, super.key});

  final TerminalRowNode node;

  @override
  Widget build(BuildContext context, WidgetRef ref) => TerminalRow(
    depth: node.depth,
    terminal: node.terminal,
    onOpen: () => _open(ref),
    onEnd: node.terminal.isHosted ? () => _end(context, ref) : null,
  );

  /// Focuses a pane already open here, or adopts a session the host is still
  /// holding into a new pane.
  void _open(WidgetRef ref) {
    final controller = ref.read(terminalSessionsControllerProvider.notifier);
    final paneId = node.terminal.paneId;
    if (!node.terminal.isHosted) {
      if (paneId != null) {
        controller.focusPane(paneId);
        controller.showTerminalHere();
      }
      return;
    }
    final hostId = ref
        .read(environmentsDataProvider)
        .getById(node.environmentId)
        ?.sshHostId;
    final host = hostId == null
        ? null
        : ref.read(sshHostsDataProvider).getById(hostId);
    if (host == null) return;
    controller.openTab(
      TerminalProfile.ssh(host.id, hostName: host.name),
      adoptPaneId: paneId,
    );
    controller.showTerminalHere();
  }

  Future<void> _end(BuildContext context, WidgetRef ref) async {
    final id = node.terminal.hostSessionId;
    if (id == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(environmentTerminalsProvider(node.environmentId).notifier)
          .end(id);
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

/// A line of prose inside the tree.
class ExplorerTreeHint extends StatelessWidget {
  const ExplorerTreeHint({
    required this.depth,
    required this.message,
    super.key,
  });

  final int depth;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final density = UiDensity.of(context);
    return Padding(
      // On the title column of a row at the same depth, so the hint reads as
      // sitting inside the node it is about rather than beside it.
      padding: EdgeInsets.fromLTRB(
        ExplorerRow.contentStartOf(density) +
            depth * ExplorerRow.indent +
            ExplorerRow.lead,
        Insets.xs,
        Insets.sm + ExplorerRow.scrollbarGutter,
        Insets.sm,
      ),
      child: Text(message, style: density.muted(theme)),
    );
  }
}
