import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ssh/connection.dart';
import 'package:karmashala_ssh/host.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../application/ssh_terminal_opener.dart';
import 'copyable_command.dart';

/// A step that needs `sudo`'s password on the machine: what it does, why this
/// app did not do it, the exact command, and a terminal there with it typed —
/// **not run** — at the prompt. No password is ever asked for or sent from
/// here, and nothing here presses Enter.
class PrivilegedCommandBlock extends ConsumerWidget {
  const PrivilegedCommandBlock({
    required this.host,
    required this.step,
    this.onCheckAgain,
    this.busy = false,
    this.closeDialogFirst = false,
    super.key,
  });

  final SshHost host;
  final PrivilegedCommand step;

  /// Re-reads the evidence — the dial, the deploy — after the command was run.
  final VoidCallback? onCheckAgain;
  final bool busy;

  /// Inside a dialog the terminal opens behind a modal barrier where nobody
  /// can type, so the dialog closes first; what it showed is reached again
  /// from where it was opened.
  final bool closeDialogFirst;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final opened = ref
        .watch(sudoTerminalsOpenedProvider)
        .contains(SudoTerminalsOpened.keyOf(host.id, step.command));
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.only(top: Insets.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(step.does, style: theme.textTheme.bodySmall),
          Text(step.why, style: muted),
          CopyableCommand(command: step.command),
          const SizedBox(height: Insets.xs),
          Wrap(
            spacing: Insets.xs,
            runSpacing: Insets.xs,
            children: [
              OutlinedButton.icon(
                onPressed: busy ? null : () => _openTerminal(context, ref),
                icon: const Icon(AppIcons.terminal, size: Chrome.icon),
                label: Text('Open a terminal on ${host.name}'),
              ),
              if (onCheckAgain != null)
                TextButton.icon(
                  onPressed: busy ? null : onCheckAgain,
                  icon: const Icon(AppIcons.arrowsClockwise, size: Chrome.icon),
                  label: const Text('Check again'),
                ),
            ],
          ),
          if (opened)
            Padding(
              padding: const EdgeInsets.only(top: Insets.xs),
              child: Text(
                'Typed at the prompt on ${host.name} and not run: press Enter '
                'there and give sudo your password in that terminal. Then '
                'choose Check again.',
                style: muted,
              ),
            ),
        ],
      ),
    );
  }

  void _openTerminal(BuildContext context, WidgetRef ref) {
    // Read before the pop: the dialog's own scope may be gone after it.
    final open = ref.read(sshTerminalOpenerProvider);
    ref.read(sudoTerminalsOpenedProvider.notifier).mark(host.id, step.command);
    if (closeDialogFirst) Navigator.of(context).pop();
    open(host, typed: step.command);
  }
}
