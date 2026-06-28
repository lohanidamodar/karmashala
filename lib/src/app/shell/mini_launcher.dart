import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../features/cli_detection/application/cli_detection_providers.dart';
import '../../features/cli_detection/domain/imported_session.dart';
import '../../features/projects/application/projects_controller.dart';
import '../../features/projects/domain/project.dart';
import '../../features/repositories/application/repository_providers.dart';
import '../../features/sessions/application/session_actions.dart';
import '../../features/sessions/application/session_providers.dart';
import '../../features/sessions/application/session_ui_providers.dart';
import '../../features/sessions/domain/session.dart';
import '../../features/settings/application/settings_controller.dart';
import '../../features/terminal/application/system_terminal_providers.dart';
import '../../features/terminal/data/system_terminal_service.dart';
import '../theme/design_tokens.dart';
import 'app_mode.dart';

/// The borderless mini launcher: projects expand to their sessions; tapping a
/// session resumes it in the default system terminal. The header is draggable
/// (the window has no title bar in mini mode).
class MiniLauncher extends ConsumerStatefulWidget {
  const MiniLauncher({super.key});

  @override
  ConsumerState<MiniLauncher> createState() => _MiniLauncherState();
}

class _MiniLauncherState extends ConsumerState<MiniLauncher> {
  final _expanded = <String>{};
  String _query = '';

  Future<void> _launch(
    SystemTerminal? terminal,
    Future<void> Function(SystemTerminal) run,
  ) async {
    if (terminal == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No terminal set. Pick one in Settings.')),
      );
      return;
    }
    String message;
    try {
      await run(terminal);
      message = 'Opening in ${terminal.label}…';
    } catch (e) {
      message = e is StateError ? e.message : '$e';
    }
    // Focus/mode may have changed during the launch — only touch the messenger
    // while still mounted, and look it up fresh (not captured across the await).
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _copyCommand(String Function() build) async {
    final messenger = ScaffoldMessenger.of(context);
    String message;
    try {
      final command = build();
      await Clipboard.setData(ClipboardData(text: command));
      message = 'Command copied to clipboard';
    } catch (e) {
      message = e is StateError ? e.message : '$e';
    }
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    ref.watch(sessionsRevisionProvider);
    final projects = ref.watch(sortedProjectsProvider);
    final pinned = ref
        .watch(settingsControllerProvider.select((s) => s.pinnedProjectIds))
        .toSet();
    final terminal = ref.watch(defaultSystemTerminalProvider).asData?.value;
    final actions = ref.read(sessionActionsProvider);
    final query = _query.trim().toLowerCase();

    return Scaffold(
      body: Column(
        children: [
          // Draggable header (no title bar in mini mode).
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => windowManager.startDragging(),
            child: Container(
              height: 38,
              color: theme.colorScheme.surfaceContainerHigh,
              padding: const EdgeInsets.only(left: Insets.md, right: 2),
              child: Row(
                children: [
                  Icon(
                    Icons.auto_stories_outlined,
                    size: 16,
                    color: theme.colorScheme.tertiary,
                  ),
                  const SizedBox(width: Insets.sm),
                  Expanded(
                    child: Text(
                      'Chitragupta',
                      style: theme.textTheme.labelLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Expand to full window',
                    iconSize: 16,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.open_in_full),
                    onPressed: () =>
                        ref.read(appModeProvider.notifier).enterFull(),
                  ),
                  IconButton(
                    tooltip: 'Hide to tray',
                    iconSize: 16,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.remove),
                    onPressed: () => windowManager.hide(),
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          if (projects.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 6, 6, 2),
              child: TextField(
                decoration: const InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(Icons.search, size: 16),
                  hintText: 'Search projects & sessions',
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
          Expanded(
            child: projects.isEmpty
                ? Center(
                    child: Text(
                      'No projects yet.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.symmetric(vertical: Insets.xs),
                    children: [
                      for (final project in projects)
                        ..._projectNodes(
                          project,
                          terminal,
                          actions,
                          query,
                          pinned.contains(project.id),
                        ),
                    ],
                  ),
          ),
          if (terminal != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: Insets.md,
                vertical: 4,
              ),
              color: theme.colorScheme.surfaceContainerLow,
              child: Text(
                'Resumes in ${terminal.label}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _projectNodes(
    Project project,
    SystemTerminal? terminal,
    SessionActions actions,
    String query,
    bool pinned,
  ) {
    final nameMatches =
        query.isEmpty || project.name.toLowerCase().contains(query);

    // Gather this project's session tiles (filtered by the query).
    final sessions = <Widget>[];
    final repos = ref.read(repositoryDaoProvider).getByProject(project.id);
    final sessionDao = ref.read(sessionDaoProvider);
    final importedDao = ref.read(importedSessionDaoProvider);
    for (final repo in repos) {
      for (final Session s in sessionDao.getByRepository(repo.id)) {
        if (query.isEmpty ||
            nameMatches ||
            s.title.toLowerCase().contains(query)) {
          sessions.add(
            _sessionTile(
              s.title,
              Icons.chat_bubble_outline,
              () => _launch(
                terminal,
                (t) => actions.openSessionInSystemTerminal(s.id, t),
              ),
              () => actions.nativeResumeShellCommand(s.id),
            ),
          );
        }
      }
      for (final ImportedSession s in importedDao.getByRepository(repo.id)) {
        if (query.isEmpty ||
            nameMatches ||
            s.displayTitle.toLowerCase().contains(query)) {
          sessions.add(
            _sessionTile(
              s.displayTitle,
              Icons.history,
              () =>
                  _launch(terminal, (t) => actions.openInSystemTerminal(s, t)),
              () => actions.resumeShellCommand(s),
            ),
          );
        }
      }
    }

    // When searching, hide projects with no name/session match; show the rest
    // force-expanded so matches are visible.
    if (query.isNotEmpty && !nameMatches && sessions.isEmpty) return const [];
    final expanded = query.isNotEmpty ? true : _expanded.contains(project.id);

    final rows = <Widget>[
      ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        leading: Icon(
          expanded ? Icons.expand_more : Icons.chevron_right,
          size: 16,
        ),
        title: Text(project.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Copy new-session command',
              iconSize: 14,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.content_copy_outlined),
              onPressed: () => _copyCommand(
                () => actions.newSessionShellCommand(project.id),
              ),
            ),
            IconButton(
              tooltip: 'New session in terminal',
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.add),
              onPressed: () => _launch(
                terminal,
                (t) => actions.startNewSessionInTerminal(project.id, t),
              ),
            ),
            IconButton(
              tooltip: pinned ? 'Unpin' : 'Pin to top',
              iconSize: 15,
              visualDensity: VisualDensity.compact,
              icon: Icon(pinned ? Icons.push_pin : Icons.push_pin_outlined),
              color: pinned ? Theme.of(context).colorScheme.tertiary : null,
              onPressed: () => ref
                  .read(settingsControllerProvider.notifier)
                  .togglePinnedProject(project.id),
            ),
          ],
        ),
        onTap: () => setState(() {
          if (!_expanded.remove(project.id)) _expanded.add(project.id);
        }),
      ),
    ];
    if (!expanded) return rows;
    if (sessions.isEmpty) {
      rows.add(
        const Padding(
          padding: EdgeInsets.fromLTRB(52, 2, 8, 8),
          child: Text('No sessions', style: TextStyle(fontSize: 12)),
        ),
      );
    } else {
      rows.addAll(sessions);
    }
    return rows;
  }

  Widget _sessionTile(
    String title,
    IconData icon,
    VoidCallback onTap,
    String Function() copyCommand,
  ) {
    return Padding(
      padding: const EdgeInsets.only(left: 24),
      child: ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        leading: Icon(icon, size: 15),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Copy resume command',
              iconSize: 13,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.content_copy_outlined),
              onPressed: () => _copyCommand(copyCommand),
            ),
            IconButton(
              tooltip: 'Resume in terminal',
              iconSize: 14,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.open_in_new),
              onPressed: onTap,
            ),
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}
