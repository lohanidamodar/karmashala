// **What the panel shows once the last terminal is closed** — a way back,
// rather than a status. A `part` because `_NoTerminalOpen` and the `_chord`
// its label is spelt with are both private to this library.

part of 'terminal_panel.dart';

/// What the panel shows once the user has closed the last terminal: a way back,
/// rather than a status. "Opening terminal…" is true for one frame and a lie
/// for as long as the layout stays closed.
class _NoTerminalOpen extends ConsumerWidget {
  const _NoTerminalOpen({required this.onNewTerminal});

  final VoidCallback onNewTerminal;

  /// The keys an empty workspace offers, by command: the few a newcomer needs
  /// to find everything else.
  static const _keys = [
    'quickOpen.show',
    'quickOpen.commands',
    'session.new',
    'project.new',
    'attention.nextWaiting',
    'settings.open',
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // Read from the table the keys run on, so a keymap edit shows at once.
    ref.watch(keymapProvider.select((k) => k.revision));
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Center(
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
          for (final command in _keys)
            if (_bound(command) case final chord?)
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
    );
  }

  /// The chord [command] is on now, preferring the one a pane lets through;
  /// null when the keymap left it without keys.
  static ShellChord? _bound(String command) {
    ShellChord? best;
    for (final chord in shellChords) {
      if (chord.command != command) continue;
      if (best == null || (!best.skipsShell && chord.skipsShell)) best = chord;
    }
    return best;
  }
}
