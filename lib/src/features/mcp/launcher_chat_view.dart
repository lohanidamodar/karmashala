import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_icons.dart';
import '../../app/theme/design_tokens.dart';
import 'launcher_chat_controller.dart';

/// A compact chat with the default agent, wired to Chitragupta's MCP tools.
/// Embedded identically in the mini launcher and the full shell — the same
/// conversation (one [launcherChatControllerProvider]) backs both.
class LauncherChatView extends ConsumerStatefulWidget {
  const LauncherChatView({super.key});

  @override
  ConsumerState<LauncherChatView> createState() => _LauncherChatViewState();
}

class _LauncherChatViewState extends ConsumerState<LauncherChatView> {
  final _input = TextEditingController();
  final _inputFocus = FocusNode();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _input.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send() {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    ref.read(launcherChatControllerProvider.notifier).send(text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = ref.watch(launcherChatControllerProvider);

    // Auto-scroll to the newest message.
    ref.listen(launcherChatControllerProvider, (_, _) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(
            _scroll.position.maxScrollExtent,
            duration: Motion.fast,
            curve: Curves.easeOut,
          );
        }
      });
    });

    // Re-focus the input when the launcher asks for focus (e.g. on hotkey).
    ref.listen(launcherFocusRequestProvider, (_, _) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _inputFocus.requestFocus();
      });
    });

    return Column(
      children: [
        Expanded(
          child: state.messages.isEmpty
              ? _EmptyState(mcpEnabled: state.mcpEnabled)
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(Insets.sm),
                  itemCount: state.messages.length,
                  itemBuilder: (_, i) => _Bubble(message: state.messages[i]),
                ),
        ),
        if (state.busy) const LinearProgressIndicator(minHeight: 2),
        Padding(
          padding: const EdgeInsets.all(Insets.sm),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  focusNode: _inputFocus,
                  autofocus: true,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Ask the agent to find or open sessions…',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: const Icon(AppIcons.paperPlaneRight, size: 18),
                      onPressed: _send,
                    ),
                  ),
                ),
              ),
              if (state.messages.isNotEmpty)
                IconButton(
                  tooltip: 'New conversation',
                  icon: const Icon(AppIcons.trash, size: 16),
                  onPressed: () =>
                      ref.read(launcherChatControllerProvider.notifier).reset(),
                ),
            ],
          ),
        ),
        if (!state.mcpEnabled && state.status != LauncherChatStatus.idle)
          Padding(
            padding: const EdgeInsets.only(bottom: Insets.sm),
            child: Text(
              'Tools unavailable (MCP bridge not found).',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.mcpEnabled});
  final bool mcpEnabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Insets.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(AppIcons.chatCircleDots, size: 28, color: theme.hintColor),
            const SizedBox(height: Insets.sm),
            Text(
              'Chat with your default agent.',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: Insets.xs),
            Text(
              'It can search your projects and sessions and act on them — e.g. '
              '"open all appwrite Claude sessions in one tmux session".',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message});
  final LauncherChatMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    switch (message.role) {
      case LauncherChatRole.tool:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              Icon(AppIcons.terminal, size: 12, color: theme.hintColor),
              const SizedBox(width: Insets.xs),
              Text(
                'called ${message.text}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.hintColor,
                ),
              ),
            ],
          ),
        );
      case LauncherChatRole.error:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: Insets.xs),
          child: Text(
            message.text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        );
      case LauncherChatRole.user:
      case LauncherChatRole.agent:
        final isUser = message.role == LauncherChatRole.user;
        return Align(
          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: Insets.xs),
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.md,
              vertical: Insets.sm,
            ),
            constraints: const BoxConstraints(maxWidth: 460),
            decoration: BoxDecoration(
              color: isUser
                  ? theme.colorScheme.primaryContainer
                  : theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(Radii.md),
            ),
            child: SelectableText(
              message.text,
              style: theme.textTheme.bodySmall,
            ),
          ),
        );
    }
  }
}
