import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../app/widgets/desktop_dialog.dart';
import '../../../app/widgets/desktop_menu.dart';
import '../../agents/domain/agent_kind.dart';
import '../application/cli_detection_providers.dart';
import '../domain/detected_project.dart';
import '../domain/detected_session.dart';

/// Browses projects and sessions auto-detected from the Claude Code and Codex
/// CLI stores. Projects are merged by path across CLIs and environments;
/// sessions are tagged by CLI, and SDK-spawned subagents are nested under their
/// project. Supports rename and delete.
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
                  icon: const Icon(AppIcons.downloadSimple, size: 18),
                  label: const Text('Import all'),
                ),
                const SizedBox(width: Insets.sm),
              ],
              FilledButton.tonalIcon(
                onPressed: () => controller.detect(),
                icon: const Icon(AppIcons.arrowsClockwise, size: 18),
                label: const Text('Detect'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: detected.when(
            loading: () => const Center(child: CircularProgressIndicator()),
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
                        'Claude Code and Codex stores (Windows + WSL).',
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
    final claude = project.countFor(AgentKind.claudeCode);
    final codex = project.countFor(AgentKind.codex);
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
          if (claude > 0) _Badge(label: 'C $claude', color: Colors.deepOrange),
          if (codex > 0) _Badge(label: 'c $codex', color: Colors.teal),
        ],
      ),
      childrenPadding: const EdgeInsets.only(left: 8, bottom: 8),
      children: [
        for (final session in project.sessions) _SessionTile(session: session),
        if (project.subagentSessions.isNotEmpty)
          ExpansionTile(
            leading: const Icon(AppIcons.treeStructure, size: 18),
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
    final cliLabel = session.cli == AgentKind.codex ? 'Codex' : 'Claude';
    return ListTile(
      dense: true,
      leading: subagent
          ? const Icon(AppIcons.arrowBendDownRight, size: 16)
          : Icon(
              session.cli == AgentKind.codex
                  ? AppIcons.terminal
                  : AppIcons.robot,
              size: 16,
            ),
      title: Text(
        session.displayTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '$cliLabel · ${session.environmentId}'
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

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label, style: TextStyle(fontSize: 11, color: color)),
    );
  }
}
