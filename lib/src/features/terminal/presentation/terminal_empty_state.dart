// **What the panel shows once the last terminal is closed** — a way back,
// rather than a status. A `part` because `_NoTerminalOpen` and the `_chord`
// its label is spelt with are both private to this library.

part of 'terminal_panel.dart';

/// What the panel shows once the user has closed the last terminal: a way back,
/// rather than a status. "Opening terminal…" is true for one frame and a lie
/// for as long as the layout stays closed.
class _NoTerminalOpen extends StatelessWidget {
  const _NoTerminalOpen({required this.onNewTerminal});

  final VoidCallback onNewTerminal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
        ],
      ),
    );
  }
}
