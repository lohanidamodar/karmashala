import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/pane_scaffold.dart';
import '../../../app/shell/shell_state.dart';
import '../../../app/theme/design_tokens.dart';
import '../../agents/domain/agent_kind.dart';
import '../../cli_detection/domain/imported_session.dart';
import '../../git/application/changes_providers.dart';
import '../application/session_actions.dart';
import '../application/session_ui_providers.dart';
import '../domain/session.dart';
import '../domain/session_status.dart';
import 'new_session_dialog.dart';

/// Middle pane — sessions for the selected repository: native engine sessions
/// and imported CLI sessions, both renamable and deletable.
class SessionsPanel extends ConsumerWidget {
  const SessionsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final focused =
        ref.watch(shellControllerProvider).focusedPane == ShellPane.sessions;
    final repoId = ref.watch(selectedRepositoryIdProvider);
    final native = ref.watch(sessionsForSelectedRepositoryProvider);
    final imported = ref.watch(importedSessionsForSelectedRepositoryProvider);

    final Widget body;
    if (repoId == null) {
      body = const PanePlaceholder(
        message: 'Select a repository to manage its sessions.',
      );
    } else if (native.isEmpty && imported.isEmpty) {
      body = const PanePlaceholder(
        message:
            'No sessions yet.\nStart one with + — or import CLI sessions from '
            'the Projects pane.',
      );
    } else {
      body = ListView(
        children: [
          for (final session in native) _NativeSessionTile(session: session),
          if (imported.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Insets.md,
                Insets.md,
                0,
                Insets.xs,
              ),
              child: Text(
                'IMPORTED (CLI)',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          for (final session in imported)
            _ImportedSessionTile(session: session),
        ],
      );
    }

    return PaneScaffold(
      title: 'Sessions',
      icon: Icons.chat_bubble_outline,
      focused: focused,
      actions: [
        IconButton(
          tooltip: repoId == null ? 'Select a repository first' : 'New session',
          icon: const Icon(Icons.add_comment_outlined, size: 18),
          onPressed: repoId == null
              ? null
              : () => NewSessionDialog.show(context),
        ),
      ],
      body: body,
    );
  }
}

class _NativeSessionTile extends ConsumerWidget {
  const _NativeSessionTile({required this.session});
  final Session session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedSessionIdProvider) == session.id;
    final actions = ref.read(sessionActionsProvider);
    return ListTile(
      dense: true,
      selected: selected,
      leading: _statusIcon(session.status, context),
      title: Text(session.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${session.status.name}'
        '${session.useWorktree ? ' · worktree' : ''}',
      ),
      trailing: _SessionMenu(
        onRename: () async {
          final name = await _promptRename(context, session.title);
          if (name != null) actions.renameNative(session.id, name);
        },
        onDelete: () async {
          if (await _confirmDelete(context, session.title, cli: false)) {
            actions.deleteNative(session.id);
          }
        },
      ),
      onTap: () {
        ref.read(selectedImportedSessionIdProvider.notifier).select(null);
        ref.read(selectedSessionIdProvider.notifier).select(session.id);
      },
    );
  }

  Widget _statusIcon(SessionStatus status, BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (IconData icon, Color color) = switch (status) {
      SessionStatus.running => (Icons.play_circle_outline, scheme.tertiary),
      SessionStatus.completed => (Icons.check_circle_outline, Colors.green),
      SessionStatus.failed => (Icons.error_outline, scheme.error),
      SessionStatus.cancelled => (Icons.cancel_outlined, scheme.outline),
      _ => (Icons.radio_button_unchecked, scheme.outline),
    };
    return Icon(icon, size: 16, color: color);
  }
}

class _ImportedSessionTile extends ConsumerWidget {
  const _ImportedSessionTile({required this.session});
  final ImportedSession session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedImportedSessionIdProvider) == session.id;
    final actions = ref.read(sessionActionsProvider);
    final cliLabel = session.cli == AgentKind.codex ? 'Codex' : 'Claude';
    return ListTile(
      dense: true,
      selected: selected,
      leading: Icon(
        session.isSubagent ? Icons.subdirectory_arrow_right : Icons.history,
        size: 16,
      ),
      title: Text(
        session.displayTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text('$cliLabel · ${session.environmentId}'),
      trailing: _SessionMenu(
        onRename: () async {
          final name = await _promptRename(context, session.displayTitle);
          if (name != null) await actions.renameImported(session, name);
        },
        onDelete: () async {
          if (await _confirmDelete(context, session.displayTitle, cli: true)) {
            await actions.deleteImported(session);
          }
        },
      ),
      onTap: () {
        ref.read(selectedSessionIdProvider.notifier).select(null);
        ref.read(selectedImportedSessionIdProvider.notifier).select(session.id);
      },
    );
  }
}

class _SessionMenu extends StatelessWidget {
  const _SessionMenu({required this.onRename, required this.onDelete});
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Session actions',
      onSelected: (a) => a == 'rename' ? onRename() : onDelete(),
      itemBuilder: (context) => const [
        PopupMenuItem(value: 'rename', child: Text('Rename')),
        PopupMenuItem(value: 'delete', child: Text('Delete')),
      ],
    );
  }
}

Future<String?> _promptRename(BuildContext context, String current) {
  final controller = TextEditingController(text: current);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Rename session'),
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

Future<bool> _confirmDelete(
  BuildContext context,
  String title, {
  required bool cli,
}) {
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Delete session?'),
      content: Text(
        cli
            ? 'Removes "$title" from the workspace and the CLI store.'
            : 'Permanently deletes "$title".',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  ).then((v) => v ?? false);
}
