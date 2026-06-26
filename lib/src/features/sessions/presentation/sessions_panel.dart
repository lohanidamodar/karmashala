import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/pane_scaffold.dart';
import '../../../app/shell/shell_state.dart';
import '../../git/application/changes_providers.dart';
import '../application/session_ui_providers.dart';
import '../domain/session_status.dart';
import 'new_session_dialog.dart';

/// Middle pane — Sessions for the selected repository. The chat-first surface:
/// start sessions and pick one to view its transcript (shown in the Detail pane).
class SessionsPanel extends ConsumerWidget {
  const SessionsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final focused =
        ref.watch(shellControllerProvider).focusedPane == ShellPane.sessions;
    final repoId = ref.watch(selectedRepositoryIdProvider);
    final sessions = ref.watch(sessionsForSelectedRepositoryProvider);
    final selectedSession = ref.watch(selectedSessionIdProvider);

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
      body: repoId == null
          ? const PanePlaceholder(
              message: 'Select a repository to manage its sessions.',
            )
          : sessions.isEmpty
          ? const PanePlaceholder(
              message: 'No sessions yet.\nUse + to start one with an agent.',
            )
          : ListView.builder(
              itemCount: sessions.length,
              itemBuilder: (context, index) {
                final session = sessions[index];
                return ListTile(
                  dense: true,
                  selected: session.id == selectedSession,
                  leading: _statusIcon(session.status, context),
                  title: Text(
                    session.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${session.status.name}'
                    '${session.useWorktree ? ' · worktree' : ''}',
                  ),
                  onTap: () => ref
                      .read(selectedSessionIdProvider.notifier)
                      .select(session.id),
                );
              },
            ),
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
