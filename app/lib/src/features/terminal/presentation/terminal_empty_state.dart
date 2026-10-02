// **What the panel shows once the last terminal is closed** — a way back,
// rather than a status. A `part` because `_NoTerminalOpen` and the `_chord`
// its label is spelt with are both private to this library.

part of 'terminal_panel.dart';

/// What the panel shows with no terminal open — at launch, since nothing opens
/// by itself, and once the last one is closed: a way in, rather than a status.
class _NoTerminalOpen extends ConsumerWidget {
  const _NoTerminalOpen({required this.onNewTerminal});

  final VoidCallback onNewTerminal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // Read from the table the keys run on, so a keymap edit shows at once.
    ref.watch(keymapProvider.select((k) => k.revision));
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    // Scrolls rather than clipping when large text outgrows a short pane.
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('No terminal open', style: theme.textTheme.bodySmall),
            const SizedBox(height: Insets.md),
            FilledButton.tonalIcon(
              onPressed: onNewTerminal,
              icon: const Icon(AppIcons.plus, size: Chrome.icon),
              label: Text(
                'New terminal${_chord(shellChordLabel<NewTerminalTabIntent>())}',
              ),
            ),
            const SizedBox(height: Insets.lg),
            for (final command in kWorkspaceKeyCommands)
              if (boundShellChord(command) case final chord?)
                Padding(
                  padding: const EdgeInsets.only(bottom: Insets.xs),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 200,
                        child: Text(
                          chord.does,
                          textAlign: TextAlign.end,
                          style: muted,
                        ),
                      ),
                      const SizedBox(width: Insets.md),
                      SizedBox(
                        width: 120,
                        child: Text(chord.label, style: MonoStyles.label),
                      ),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }
}
