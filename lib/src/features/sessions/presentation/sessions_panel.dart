import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/pane_scaffold.dart';
import '../../../app/shell/shell_state.dart';

/// Middle pane — Sessions (the chat-first list of agent sessions).
///
/// Placeholder for Loop 0. The concurrent session list and structured chat
/// arrive in the session engine loop (Loop 6) onward.
class SessionsPanel extends ConsumerWidget {
  const SessionsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final focused =
        ref.watch(shellControllerProvider).focusedPane == ShellPane.sessions;
    return PaneScaffold(
      title: 'Sessions',
      icon: Icons.chat_bubble_outline,
      focused: focused,
      actions: [
        IconButton(
          tooltip: 'New session (coming soon)',
          icon: const Icon(Icons.add_comment_outlined, size: 18),
          onPressed: null,
        ),
      ],
      body: const PanePlaceholder(
        message:
            'Active agent sessions will appear here.\nStructured chat arrives from Loop 6.',
      ),
    );
  }
}
