import 'package:flutter/material.dart';
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

  Future<void> _launch(
    SystemTerminal? terminal,
    Future<void> Function(SystemTerminal) run,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    if (terminal == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('No terminal set. Pick one in Settings.')),
      );
      return;
    }
    try {
      await run(terminal);
      messenger.showSnackBar(
        SnackBar(content: Text('Opening in ${terminal.label}…')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e is StateError ? e.message : '$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    ref.watch(sessionsRevisionProvider);
    final projects = ref.watch(projectsControllerProvider);
    final terminal = ref.watch(defaultSystemTerminalProvider).asData?.value;
    final actions = ref.read(sessionActionsProvider);

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
                        ..._projectNodes(project, terminal, actions),
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
  ) {
    final expanded = _expanded.contains(project.id);
    final rows = <Widget>[
      ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        leading: Icon(
          expanded ? Icons.expand_more : Icons.chevron_right,
          size: 16,
        ),
        title: Text(project.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        onTap: () => setState(() {
          if (!_expanded.remove(project.id)) _expanded.add(project.id);
        }),
      ),
    ];
    if (!expanded) return rows;

    final repos = ref.read(repositoryDaoProvider).getByProject(project.id);
    final sessionDao = ref.read(sessionDaoProvider);
    final importedDao = ref.read(importedSessionDaoProvider);
    var any = false;
    for (final repo in repos) {
      for (final Session s in sessionDao.getByRepository(repo.id)) {
        any = true;
        rows.add(
          _sessionTile(
            s.title,
            Icons.chat_bubble_outline,
            () => _launch(
              terminal,
              (t) => actions.openSessionInSystemTerminal(s.id, t),
            ),
          ),
        );
      }
      for (final ImportedSession s in importedDao.getByRepository(repo.id)) {
        any = true;
        rows.add(
          _sessionTile(
            s.displayTitle,
            Icons.history,
            () => _launch(terminal, (t) => actions.openInSystemTerminal(s, t)),
          ),
        );
      }
    }
    if (!any) {
      rows.add(
        const Padding(
          padding: EdgeInsets.fromLTRB(52, 2, 8, 8),
          child: Text('No sessions', style: TextStyle(fontSize: 12)),
        ),
      );
    }
    return rows;
  }

  Widget _sessionTile(String title, IconData icon, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(left: 24),
      child: ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        leading: Icon(icon, size: 15),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: const Icon(Icons.open_in_new, size: 14),
        onTap: onTap,
      ),
    );
  }
}
