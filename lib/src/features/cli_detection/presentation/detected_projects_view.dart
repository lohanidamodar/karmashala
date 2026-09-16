import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../environments/application/environments_controller.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:agent_cli/descriptors.dart';
import '../application/cli_detection_providers.dart';
import 'package:agent_cli/read.dart';

/// Browses projects and sessions auto-detected from the CLI stores. Projects
/// merge by path across CLIs and environments; subagents nest under a project.
class DetectedProjectsView extends ConsumerWidget {
  const DetectedProjectsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final detected = ref.watch(detectedProjectsControllerProvider);
    final controller = ref.read(detectedProjectsControllerProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
          child: Row(
            children: [
              Icon(AppIcons.globe, color: theme.colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Detected sessions (Claude Code · Codex)',
                  style: theme.textTheme.titleMedium,
                ),
              ),
              if (detected.asData?.value.isNotEmpty ?? false) ...[
                FilledButton.icon(
                  onPressed: () {
                    final summary = controller.importAll();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          summary.isEmpty
                              ? 'Already imported — nothing new.'
                              : 'Imported ${summary.projects} project(s), '
                                    '${summary.sessions} session(s).',
                        ),
                      ),
                    );
                  },
                  icon: const Icon(AppIcons.downloadSimple),
                  label: const Text('Import all'),
                ),
                const SizedBox(width: Insets.sm),
              ],
              FilledButton.tonalIcon(
                onPressed: () => controller.detect(),
                icon: const Icon(AppIcons.arrowsClockwise),
                label: const Text('Detect'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: detected.when(
            loading: () => const Center(
              child: InlineSpinner(size: InlineSpinnerSize.large),
            ),
            error: (e, _) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '$e',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            ),
            data: (projects) => projects.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'No sessions detected yet.\nPress Detect to scan the '
                        'Claude Code, Codex, and Antigravity stores (Windows + WSL).',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: projects.length,
                    itemBuilder: (context, index) =>
                        _ProjectTile(project: projects[index]),
                  ),
          ),
        ),
      ],
    );
  }
}

class _ProjectTile extends StatelessWidget {
  const _ProjectTile({required this.project});
  final DetectedProject project;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final claude = project.countFor(AgentIds.claudeCode);
    final codex = project.countFor(AgentIds.codex);
    final antigravity = project.countFor(AgentIds.antigravity);
    return ExpansionTile(
      leading: const Icon(AppIcons.folder),
      title: Text(project.name),
      subtitle: Text(
        project.displayPath,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      trailing: Wrap(
        spacing: 6,
        children: [
          if (claude > 0) _Badge(agentId: AgentIds.claudeCode, count: claude),
          if (codex > 0) _Badge(agentId: AgentIds.codex, count: codex),
          if (antigravity > 0)
            _Badge(agentId: AgentIds.antigravity, count: antigravity),
        ],
      ),
      childrenPadding: const EdgeInsets.only(left: 8, bottom: 8),
      children: [
        for (final session in project.sessions) _SessionTile(session: session),
        if (project.subagentSessions.isNotEmpty)
          ExpansionTile(
            leading: const Icon(AppIcons.treeStructure),
            title: Text('Subagents (${project.subagentSessions.length})'),
            childrenPadding: const EdgeInsets.only(left: 16),
            children: [
              for (final session in project.subagentSessions)
                _SessionTile(session: session, subagent: true),
            ],
          ),
      ],
    );
  }
}

class _SessionTile extends ConsumerWidget {
  const _SessionTile({required this.session, this.subagent = false});
  final DetectedSession session;
  final bool subagent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final controller = ref.read(detectedProjectsControllerProvider.notifier);
    final cliLabel = AgentRegistry.builtIn.displayNameFor(session.cli);
    return ListTile(
      dense: true,
      leading: subagent
          ? const Icon(AppIcons.arrowBendDownRight)
          : Icon(
              session.cli == AgentIds.codex
                  ? AppIcons.terminal
                  : AppIcons.robot,
            ),
      title: Text(
        session.displayTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '$cliLabel · '
        '${ref.watch(environmentLabelForIdProvider(session.environmentId))}'
        '${session.entrypoint == null ? '' : ' · ${session.entrypoint}'}',
        style: theme.textTheme.bodySmall,
      ),
      trailing: PopupMenuButton<String>(
        tooltip: 'Session actions',
        onSelected: (action) async {
          if (action == 'rename') {
            final name = await _promptRename(context, session.displayTitle);
            if (name != null) await controller.renameSession(session, name);
          } else if (action == 'delete') {
            final ok = await _confirmDelete(context, session.displayTitle);
            if (ok) await controller.deleteSession(session);
          }
        },
        itemBuilder: (context) => [
          DesktopMenuItem(
            value: 'rename',
            label: 'Rename',
            icon: AppIcons.pencilSimple,
          ),
          const DesktopMenuDivider(),
          DesktopMenuItem(
            value: 'delete',
            label: 'Delete from CLI store',
            icon: AppIcons.trash,
            destructive: true,
          ),
        ],
      ),
    );
  }

  Future<String?> _promptRename(BuildContext context, String current) {
    final controller = TextEditingController(text: current);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const DesktopDialogTitle(
          icon: AppIcons.pencilSimple,
          title: 'Rename session',
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Title'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Rename'),
          ),
        ],
      ),
    ).then((v) => (v == null || v.isEmpty) ? null : v);
  }

  Future<bool> _confirmDelete(BuildContext context, String title) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const DesktopDialogTitle(
          icon: AppIcons.trash,
          title: 'Delete session?',
          subtitle: 'This permanently removes it from the CLI store.',
        ),
        content: Text('This permanently deletes "$title" from the CLI store.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    ).then((v) => v ?? false);
  }
}

/// How many sessions one CLI contributed to a project. Named in words, not by
/// hue: the app has one accent, and a colour alone is not a label.
class _Badge extends StatelessWidget {
  const _Badge({required this.agentId, required this.count});

  final String agentId;
  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // "Claude Code" → "Claude": short enough for a trailing badge, and read
    // from the registry so it cannot drift from what the app calls the agent.
    final name = AgentRegistry.builtIn.displayNameFor(agentId).split(' ').first;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.sm,
        vertical: Insets.xs,
      ),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Text(
        '$name $count',
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: scheme.primary),
      ),
    );
  }
}
