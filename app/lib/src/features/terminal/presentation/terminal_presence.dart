import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_terminal_runtime/host_link.dart' show HostPresence;
import 'package:karmashala_terminal_runtime/instances.dart';
import 'package:karmashala_ui/tokens.dart';

import '../application/terminal_sessions_controller.dart';

/// Several clients on one session (slice 5e), as the pane shows it: while
/// someone else is typing, "Typing: *client* — Take over" over the top (a
/// keystroke here takes over by itself once they have been idle 3 s); while
/// the session is at someone else's grid, a note saying whose.
class TerminalPresence extends ConsumerWidget {
  const TerminalPresence({
    required this.paneId,
    required this.child,
    super.key,
  });

  final String paneId;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final instance = ref
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(paneId);
    if (instance is! HostTerminalInstance) return child;
    return ValueListenableBuilder<HostPresence?>(
      valueListenable: instance.presence,
      builder: (context, presence, _) {
        if (presence == null ||
            (!presence.heldElsewhere && !presence.sizedElsewhere)) {
          return child;
        }
        return Stack(
          children: [
            Positioned.fill(child: child),
            if (presence.heldElsewhere)
              Positioned(
                top: Insets.xs,
                right: Insets.xs,
                child: _TypingBanner(
                  holder: presence.holder!,
                  onTakeOver: instance.takeOver,
                ),
              ),
            if (presence.sizedElsewhere)
              Positioned(
                bottom: Insets.xs,
                right: Insets.xs,
                child: _Note(
                  'Sized for ${presence.sizedFor} '
                  '(${presence.columns}×${presence.rows})',
                ),
              ),
          ],
        );
      },
    );
  }
}

class _TypingBanner extends StatelessWidget {
  const _TypingBanner({required this.holder, required this.onTakeOver});

  final String holder;
  final Future<void> Function() onTakeOver;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.secondaryContainer,
      borderRadius: BorderRadius.circular(Radii.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Typing: $holder',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ),
            const SizedBox(width: Insets.xs),
            TextButton(
              key: const Key('terminal-take-over'),
              onPressed: onTakeOver,
              child: const Text('Take over'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.sm,
            vertical: Insets.xs,
          ),
          child: Text(text, style: theme.textTheme.labelSmall),
        ),
      ),
    );
  }
}
