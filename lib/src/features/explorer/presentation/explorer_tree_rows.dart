import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../environments/application/environment_providers.dart';
import '../../settings/application/settings_controller.dart';
import '../../ssh/application/ssh_providers.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../application/environment_terminals_providers.dart';
import '../application/explorer_tree_nodes.dart';
import '../application/explorer_tree_provider.dart';
import '../application/explorer_tree_state.dart';
import 'environment_rows.dart';
import 'explorer_project_row.dart';
import 'session_rows.dart';

/// One Explorer row for [node]. Each kind is its own widget so that the
/// readings a row needs are watched by that row alone.
class ExplorerTreeRow extends StatelessWidget {
  const ExplorerTreeRow({required this.node, this.anchorKey, super.key});

  final ExplorerNode node;

  /// Handed to the selected project's row — see [ExplorerProjectRow.anchorKey].
  final Key? anchorKey;

  @override
  Widget build(BuildContext context) => switch (node) {
    final EnvironmentNode node => ExplorerEnvironmentRow(node: node),
    final EnvironmentSectionNode node => ExplorerSectionHeaderRow(node: node),
    final ContextNode node => ExplorerContextRow(node: node),
    final ProjectNode node => ExplorerProjectRow(
      project: node.project,
      depth: node.depth,
      expanded: node.expanded,
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

void _toggleCollapsed(WidgetRef ref, String nodeId) => ref
    .read(settingsControllerProvider.notifier)
    .toggleExplorerNodeCollapsed(nodeId);

/// A machine.
class ExplorerEnvironmentRow extends ConsumerWidget {
  const ExplorerEnvironmentRow({required this.node, super.key});

  final EnvironmentNode node;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ExplorerHeaderRow(
    depth: node.depth,
    expanded: node.expanded,
    label: node.label,
    icon: environmentGlyph(node.kind),
    emphasis: HeaderEmphasis.machine,
    trailingText: node.projectCount == 0 ? null : '${node.projectCount}',
    trailingTooltip: environmentSummary(node),
    tooltip: node.environment == null
        ? 'This environment is no longer in the workspace.'
        : null,
    onTap: () => _toggleCollapsed(ref, node.id),
    // Not offered for a machine whose row is gone: we cannot say what it is,
    // and the fallback would quietly open a shell on this one.
    action: node.environment == null
        ? null
        : ExplorerRowAction(
            tooltip: 'Open a terminal on ${node.label}',
            icon: AppIcons.plus,
            onPressed: () => _openTerminalOn(ref),
          ),
  );

  void _openTerminalOn(WidgetRef ref) {
    final controller = ref.read(terminalSessionsControllerProvider.notifier);
    final environment = node.environment;
    final distro = environment?.wslDistribution ?? environment?.name ?? '';
    controller.openTab(switch (environment?.kind) {
      EnvironmentKind.ssh when environment?.sshHostId != null =>
        TerminalProfile.ssh(
          environment!.sshHostId!,
          hostName: environment.name,
        ),
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
}

/// `Projects` or `Terminals` under a machine.
class ExplorerSectionHeaderRow extends ConsumerWidget {
  const ExplorerSectionHeaderRow({required this.node, super.key});

  final EnvironmentSectionNode node;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ExplorerHeaderRow(
    depth: node.depth,
    expanded: node.expanded,
    label: node.label,
    trailingText: node.count == null ? null : '${node.count}',
    detail: node.detail,
    onTap: () => node.section == EnvironmentSection.terminals
        ? _toggleTerminals(ref)
        : _toggleCollapsed(ref, node.id),
  );

  /// Opening a machine's terminals asks it; closing one asks nothing. The
  /// answer is never refreshed on a timer (§19).
  void _toggleTerminals(WidgetRef ref) {
    final opening = ref
        .read(explorerExpandedTerminalsProvider.notifier)
        .toggle(node.environmentId);
    if (opening) {
      ref
          .read(environmentTerminalsProvider(node.environmentId).notifier)
          .refresh();
    }
  }
}

/// A context among a machine's projects.
class ExplorerContextRow extends ConsumerWidget {
  const ExplorerContextRow({required this.node, super.key});

  final ContextNode node;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ExplorerHeaderRow(
    depth: node.depth,
    expanded: node.expanded,
    label: node.label,
    icon: AppIcons.stack,
    emphasis: HeaderEmphasis.context,
    trailingText: '${node.projectCount}',
    trailingTooltip:
        '${node.projectCount} project${node.projectCount == 1 ? '' : 's'}',
    onTap: () => _toggleCollapsed(ref, node.id),
  );
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
        .read(executionEnvironmentDaoProvider)
        .getById(node.environmentId)
        ?.sshHostId;
    final host = hostId == null
        ? null
        : ref.read(sshHostDaoProvider).getById(hostId);
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
        Insets.sm,
        Insets.sm,
      ),
      child: Text(message, style: density.muted(theme)),
    );
  }
}
