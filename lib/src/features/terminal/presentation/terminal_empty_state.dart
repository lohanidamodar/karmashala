// **What the panel shows once the last terminal is closed** — a way back,
// rather than a status.
//
// A part of `terminal_panel.dart` rather than a library of its own, twice
// over: `_NoTerminalOpen` is private and the tree golden records that name,
// and the chord in its button's label is spelt with `_chord`, which is
// private to this library and lives beside the toolbar that also reads it.

part of 'terminal_panel.dart';

/// What the panel shows once the user has closed the last terminal.
///
/// A way back, rather than a status. The panel used to say "Opening terminal…"
/// here, which is true for the one frame before the automatic open and a lie
/// for as long as the layout stays closed — and it left the only route back
/// to a terminal in the toolbar, which reads as chrome rather than as the
/// answer to an empty layout.
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
          const SizedBox(height: 12),
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
