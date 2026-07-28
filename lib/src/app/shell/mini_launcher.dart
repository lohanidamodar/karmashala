import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../features/cli_detection/application/cli_detection_providers.dart';
import '../../features/cli_detection/domain/imported_session.dart';
import '../../features/editor/application/code_editor_providers.dart';
import '../../features/projects/application/projects_controller.dart';
import '../../features/projects/domain/project.dart';
import '../../features/repositories/application/repository_providers.dart';
import '../../features/sessions/application/session_actions.dart';
import '../../features/sessions/application/session_providers.dart';
import '../../features/sessions/application/session_ui_providers.dart';
import '../../features/sessions/domain/session.dart';
import '../../features/settings/application/settings_controller.dart';
import '../../features/terminal/application/system_terminal_providers.dart';
import '../../features/mcp/launcher_chat_controller.dart';
import '../../features/mcp/launcher_chat_view.dart';
import '../../features/terminal/data/system_terminal_service.dart';
import '../widgets/desktop_menu.dart';
import '../theme/app_icons.dart';
import '../theme/design_tokens.dart';
import 'app_mode.dart';

/// Below this width the mini launcher stays minimal (tap to act); at or above it
/// the window is "expanded" and rows gain a right-click context menu like the
/// full Explorer.
const double _miniWideBreakpoint = 420;

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

  /// Opens [project] in the configured code editor; with [chooseSubfolder] a
  /// directory picker (rooted at the project) lets the user pick a sub-folder.
  Future<void> _openEditor(
    Project project, {
    bool chooseSubfolder = false,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final editor = ref.read(editorActionsProvider);
    String? subPath;
    if (chooseSubfolder) {
      final picked = await getDirectoryPath(
        initialDirectory: editor.windowsRootPath(project),
        confirmButtonText: 'Open in editor',
      );
      if (picked == null) return;
      subPath = picked;
    }
    try {
      await editor.openProject(project.id, windowsSubPath: subPath);
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Opening in editor…')),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(e is StateError ? e.message : '$e')),
      );
    }
  }

  Future<void> _syncProject(Project project) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await ref
          .read(projectsControllerProvider.notifier)
          .syncSessions(project.id);
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            result.sessions == 0
                ? 'Sessions are up to date.'
                : 'Added ${result.sessions} CLI session'
                      '${result.sessions == 1 ? '' : 's'}.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Could not refresh sessions: $e')),
      );
    }
  }

  /// Shows a context menu at [global] and returns the chosen value.
  Future<String?> _rowMenu(Offset global, List<PopupMenuEntry<String>> items) {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    return showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        global.dx,
        global.dy,
        overlay.size.width - global.dx,
        overlay.size.height - global.dy,
      ),
      items: items,
    );
  }

  Future<void> _renameSession(
    String current,
    Future<void> Function(String) onSubmit,
  ) async {
    final controller = TextEditingController(text: current);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename session'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Title'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;
    await onSubmit(name);
  }

  Future<void> _confirmAndRun(
    String title,
    String message,
    Future<void> Function() onConfirm, {
    String confirmLabel = 'Delete',
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    if (ok ?? false) await onConfirm();
  }

  Future<void> _projectMenu(
    Offset pos,
    Project project,
    SystemTerminal? terminal,
    SessionActions actions,
    bool pinned,
  ) async {
    final action = await _rowMenu(pos, [
      DesktopMenuItem(
        value: 'new',
        label: 'New session in terminal',
        icon: AppIcons.plus,
      ),
      DesktopMenuItem(
        value: 'copy',
        label: 'Copy new-session command',
        icon: AppIcons.copy,
      ),
      DesktopMenuItem(
        value: 'editor',
        label: 'Open in editor',
        icon: AppIcons.code,
      ),
      DesktopMenuItem(
        value: 'editor-sub',
        label: 'Open sub-folder in editor…',
        icon: AppIcons.folderOpen,
      ),
      DesktopMenuItem(
        value: 'pin',
        label: pinned ? 'Unpin' : 'Pin to top',
        icon: AppIcons.pushPin,
      ),
      DesktopMenuItem(
        value: 'refresh',
        label: 'Refresh CLI sessions',
        icon: AppIcons.arrowsClockwise,
      ),
      const DesktopMenuDivider(),
      DesktopMenuItem(
        value: 'remove',
        label: 'Remove from workspace',
        icon: AppIcons.trash,
        destructive: true,
      ),
    ]);
    switch (action) {
      case 'new':
        await _launch(
          terminal,
          (t) => actions.startNewSessionInTerminal(project.id, t),
        );
      case 'copy':
        await _copyCommand(() => actions.newSessionShellCommand(project.id));
      case 'editor':
        await _openEditor(project);
      case 'editor-sub':
        await _openEditor(project, chooseSubfolder: true);
      case 'pin':
        ref
            .read(settingsControllerProvider.notifier)
            .togglePinnedProject(project.id);
      case 'refresh':
        await _syncProject(project);
      case 'remove':
        await _confirmAndRun(
          'Remove project?',
          'Removes "${project.name}" and its sessions from the workspace. '
              'Files on disk are not touched.',
          () async => ref
              .read(projectsControllerProvider.notifier)
              .deleteProject(project.id),
          confirmLabel: 'Remove',
        );
    }
  }

  Future<void> _sessionMenu(
    Offset pos, {
    required VoidCallback onResume,
    required String Function() copyCommand,
    required Future<void> Function() onRename,
    required Future<void> Function() onDelete,
    required bool pinned,
    required VoidCallback onTogglePin,
  }) async {
    final action = await _rowMenu(pos, [
      DesktopMenuItem(
        value: 'resume',
        label: 'Resume in terminal',
        icon: AppIcons.arrowSquareOut,
      ),
      DesktopMenuItem(
        value: 'copy',
        label: 'Copy resume command',
        icon: AppIcons.copy,
      ),
      DesktopMenuItem(
        value: 'pin',
        label: pinned ? 'Unpin' : 'Pin to top',
        icon: pinned ? AppIcons.pushPinFill : AppIcons.pushPin,
      ),
      const DesktopMenuDivider(),
      DesktopMenuItem(
        value: 'rename',
        label: 'Rename…',
        icon: AppIcons.pencilSimple,
      ),
      DesktopMenuItem(
        value: 'delete',
        label: 'Delete…',
        icon: AppIcons.trash,
        destructive: true,
      ),
    ]);
    switch (action) {
      case 'resume':
        onResume();
      case 'copy':
        await _copyCommand(copyCommand);
      case 'pin':
        onTogglePin();
      case 'rename':
        await onRename();
      case 'delete':
        await onDelete();
    }
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
    final chatVisible = ref.watch(launcherChatVisibleProvider);

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
                    AppIcons.bookOpen,
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
                    tooltip: chatVisible ? 'Back to launcher' : 'Chat with agent',
                    iconSize: 16,
                    isSelected: chatVisible,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(AppIcons.chatCircleDots),
                    onPressed: () =>
                        ref.read(launcherChatVisibleProvider.notifier).toggle(),
                  ),
                  IconButton(
                    tooltip: 'Expand to full window',
                    iconSize: 16,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(AppIcons.arrowsOutSimple),
                    onPressed: () =>
                        ref.read(appModeProvider.notifier).enterFull(),
                  ),
                  IconButton(
                    tooltip: 'Hide to tray',
                    iconSize: 16,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(AppIcons.x),
                    onPressed: () => windowManager.hide(),
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          if (chatVisible)
            const Expanded(child: LauncherChatView())
          else ...[
          if (projects.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 6, 6, 2),
              child: TextField(
                decoration: const InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(AppIcons.magnifyingGlass, size: 16),
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
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final isWide =
                          constraints.maxWidth >= _miniWideBreakpoint;
                      return ListView(
                        padding: const EdgeInsets.symmetric(
                          vertical: Insets.xs,
                        ),
                        children: [
                          for (final project in projects)
                            ..._projectNodes(
                              project,
                              terminal,
                              actions,
                              query,
                              pinned.contains(project.id),
                              isWide,
                            ),
                        ],
                      );
                    },
                  ),
          ),
          ],
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
    bool isWide,
  ) {
    final nameMatches =
        query.isEmpty || project.name.toLowerCase().contains(query);

    // Gather this project's sessions (filtered by the query), newest first with
    // pinned sessions on top.
    final pinnedSessions = ref
        .watch(settingsControllerProvider.select((s) => s.pinnedSessionIds))
        .toSet();
    final settings = ref.read(settingsControllerProvider.notifier);
    final entries = <({DateTime ts, bool pinned, Widget row})>[];
    final repos = ref.read(repositoryDaoProvider).getByProject(project.id);
    final sessionDao = ref.read(sessionDaoProvider);
    final importedDao = ref.read(importedSessionDaoProvider);
    for (final repo in repos) {
      for (final Session s in sessionDao.getByRepository(repo.id)) {
        if (query.isNotEmpty &&
            !nameMatches &&
            !s.title.toLowerCase().contains(query)) {
          continue;
        }
        final isPinned = pinnedSessions.contains(s.id);
        entries.add((
          ts: s.createdAt,
          pinned: isPinned,
          row: _sessionTile(
            title: s.title,
            icon: AppIcons.chatCircle,
            pinned: isPinned,
            onTap: () => _launch(
              terminal,
              (t) => actions.openSessionInSystemTerminal(s.id, t),
            ),
            copyCommand: () => actions.nativeResumeShellCommand(s.id),
            onContextMenu: !isWide
                ? null
                : (pos) => _sessionMenu(
                    pos,
                    onResume: () => _launch(
                      terminal,
                      (t) => actions.openSessionInSystemTerminal(s.id, t),
                    ),
                    copyCommand: () => actions.nativeResumeShellCommand(s.id),
                    onRename: () => _renameSession(
                      s.title,
                      (name) async => actions.renameNative(s.id, name),
                    ),
                    onDelete: () => _confirmAndRun(
                      'Delete session?',
                      'Removes "${s.title}".',
                      () => actions.deleteNative(s.id),
                    ),
                    pinned: isPinned,
                    onTogglePin: () => settings.togglePinnedSession(s.id),
                  ),
          ),
        ));
      }
      for (final ImportedSession s in importedDao.getByRepository(repo.id)) {
        if (query.isNotEmpty &&
            !nameMatches &&
            !s.displayTitle.toLowerCase().contains(query)) {
          continue;
        }
        final isPinned = pinnedSessions.contains(s.id);
        entries.add((
          ts: s.updatedAt ?? s.createdAt,
          pinned: isPinned,
          row: _sessionTile(
            title: s.displayTitle,
            icon: AppIcons.clockCounterClockwise,
            pinned: isPinned,
            onTap: () =>
                _launch(terminal, (t) => actions.openInSystemTerminal(s, t)),
            copyCommand: () => actions.resumeShellCommand(s),
            onContextMenu: !isWide
                ? null
                : (pos) => _sessionMenu(
                    pos,
                    onResume: () => _launch(
                      terminal,
                      (t) => actions.openInSystemTerminal(s, t),
                    ),
                    copyCommand: () => actions.resumeShellCommand(s),
                    onRename: () => _renameSession(
                      s.displayTitle,
                      (name) => actions.renameImported(s, name),
                    ),
                    onDelete: () => _confirmAndRun(
                      'Delete session?',
                      'Removes "${s.displayTitle}".',
                      () => actions.deleteImported(s),
                    ),
                    pinned: isPinned,
                    onTogglePin: () => settings.togglePinnedSession(s.id),
                  ),
          ),
        ));
      }
    }
    entries.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return b.ts.compareTo(a.ts);
    });
    final sessions = [for (final e in entries) e.row];

    // When searching, hide projects with no name/session match; show the rest
    // force-expanded so matches are visible.
    if (query.isNotEmpty && !nameMatches && sessions.isEmpty) return const [];
    final expanded = query.isNotEmpty ? true : _expanded.contains(project.id);

    final projectTile = ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      leading: Icon(
        expanded ? AppIcons.caretDown : AppIcons.caretRight,
        size: 16,
      ),
      title: Text(project.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Open in editor',
            iconSize: 14,
            visualDensity: VisualDensity.compact,
            icon: const Icon(AppIcons.code),
            onPressed: () => _openEditor(project),
          ),
          IconButton(
            tooltip: 'Copy new-session command',
            iconSize: 14,
            visualDensity: VisualDensity.compact,
            icon: const Icon(AppIcons.copy),
            onPressed: () =>
                _copyCommand(() => actions.newSessionShellCommand(project.id)),
          ),
          IconButton(
            tooltip: 'New session in terminal',
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            icon: const Icon(AppIcons.plus),
            onPressed: () => _launch(
              terminal,
              (t) => actions.startNewSessionInTerminal(project.id, t),
            ),
          ),
          IconButton(
            tooltip: pinned ? 'Unpin' : 'Pin to top',
            iconSize: 15,
            visualDensity: VisualDensity.compact,
            icon: Icon(pinned ? AppIcons.pushPinFill : AppIcons.pushPin),
            color: pinned ? Theme.of(context).colorScheme.tertiary : null,
            onPressed: () => ref
                .read(settingsControllerProvider.notifier)
                .togglePinnedProject(project.id),
          ),
        ],
      ),
      onTap: () {
        final expanding = !_expanded.contains(project.id);
        setState(() {
          if (expanding) {
            _expanded.add(project.id);
          } else {
            _expanded.remove(project.id);
          }
        });
        // Refresh live CLI sessions on expand so the newest surface.
        if (expanding) {
          ref
              .read(projectsControllerProvider.notifier)
              .syncSessions(project.id);
        }
      },
    );

    final rows = <Widget>[
      isWide
          ? GestureDetector(
              behavior: HitTestBehavior.opaque,
              onSecondaryTapDown: (d) => _projectMenu(
                d.globalPosition,
                project,
                terminal,
                actions,
                pinned,
              ),
              child: projectTile,
            )
          : projectTile,
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

  Widget _sessionTile({
    required String title,
    required IconData icon,
    required VoidCallback onTap,
    required String Function() copyCommand,
    bool pinned = false,
    void Function(Offset)? onContextMenu,
  }) {
    final tile = Padding(
      padding: const EdgeInsets.only(left: 24),
      child: ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        leading: Icon(icon, size: 15),
        title: Row(
          children: [
            if (pinned) ...[
              Icon(
                AppIcons.pushPinFill,
                size: 10,
                color: Theme.of(context).colorScheme.tertiary,
              ),
              const SizedBox(width: 4),
            ],
            Expanded(
              child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Copy resume command',
              iconSize: 13,
              visualDensity: VisualDensity.compact,
              icon: const Icon(AppIcons.copy),
              onPressed: () => _copyCommand(copyCommand),
            ),
            IconButton(
              tooltip: 'Resume in terminal',
              iconSize: 14,
              visualDensity: VisualDensity.compact,
              icon: const Icon(AppIcons.arrowSquareOut),
              onPressed: onTap,
            ),
          ],
        ),
        onTap: onTap,
      ),
    );
    if (onContextMenu == null) return tile;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapDown: (d) => onContextMenu(d.globalPosition),
      child: tile,
    );
  }
}
