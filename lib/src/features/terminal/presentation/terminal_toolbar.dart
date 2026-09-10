// **The group's own toolbar**, and the three chord lookups its tooltips are
// written with. A `part` because `_chord` and its two narrowing helpers are
// private and `_NoTerminalOpen` spells its own chord with them.

part of 'terminal_panel.dart';

/// One workspace group's own toolbar — find, split, new tab, and the commands
/// button that only appears when it has something to say. Beside that group's
/// tabs, because every verb here acts on *that* group's focused pane; anything
/// about the whole window is in [ShellTitleBar] instead.
class TerminalToolbar extends ConsumerWidget {
  const TerminalToolbar({this.compact = false, super.key});

  /// Only the way to make another terminal, for a window too narrow for the
  /// rest of the row: the other five are a chord and a palette command each,
  /// but **the `+` must never be off screen**.
  final bool compact;

  /// Builds of this widget, for `snippet_button_cost_test.dart`: this row sits
  /// above a terminal somebody types into all day, and counting is the only way
  /// to keep proving it does not wake for a character.
  @visibleForTesting
  static int debugBuildCount = 0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    debugBuildCount++;
    final actions = TerminalActions(ref);
    final hasTabs = ref.watch(
      terminalSessionsControllerProvider.select((s) => s.tabs.isNotEmpty),
    );
    final hasCommands = actions.focusedBlocks().isNotEmpty;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!compact && hasCommands)
          IconButton(
            tooltip: 'Commands',
            icon: const Icon(AppIcons.clockCounterClockwise, size: Chrome.icon),
            onPressed: () => actions.showCommands(context),
          ),
        // Deliberately **unconditional**: it never asks how many snippets there
        // are, so the strip takes out no subscription a write to the library
        // could wake. The picker answers the empty case.
        if (!compact) IconButton(
          tooltip:
              'Command snippets'
              '${_chord(_snippetChord())}',
          icon: const Icon(AppIcons.bookBookmark, size: Chrome.icon),
          onPressed: hasTabs
              ? () => QuickOpen.show(context, initialQuery: r'$')
              : null,
        ),
        if (!compact) IconButton(
          tooltip:
              'Find in scrollback'
              '${_chord(shellChordLabel<FindInScrollbackIntent>())}',
          icon: const Icon(AppIcons.magnifyingGlass, size: Chrome.icon),
          onPressed: hasTabs ? actions.openSearch : null,
        ),
        if (!compact) IconButton(
          tooltip:
              'Split the workspace right'
              '${_chord(_splitChord(SplitAxis.horizontal))}',
          // `sidebarSimple` means the side panel everywhere else in the
          // chrome, so a split gets its own shape.
          icon: const Icon(AppIcons.squareSplitHorizontal, size: Chrome.icon),
          onPressed: hasTabs ? () => actions.split(SplitAxis.horizontal) : null,
        ),
        if (!compact) IconButton(
          tooltip:
              'Split the workspace down'
              '${_chord(_splitChord(SplitAxis.vertical))}',
          icon: const Icon(AppIcons.squareSplitVertical, size: Chrome.icon),
          onPressed: hasTabs ? () => actions.split(SplitAxis.vertical) : null,
        ),
        // Two controls, the way VS Code splits them: one button that could only
        // open a menu made the common case cost a choice.
        IconButton(
          tooltip: 'New terminal${_chord(shellChordLabel<NewTerminalTabIntent>())}',
          icon: const Icon(AppIcons.plus, size: Chrome.icon),
          onPressed: () => actions.open(actions.defaultProfile()),
        ),
        PopupMenuButton<TerminalProfile>(
          tooltip: 'New terminal with a different profile',
          icon: const Icon(AppIcons.caretDown, size: Chrome.iconSmall),
          // A hair beside the +, not a second button's width away.
          constraints: const BoxConstraints(minWidth: 180),
          padding: EdgeInsets.zero,
          iconSize: Chrome.iconSmall,
          onSelected: actions.open,
          itemBuilder: (context) => [
            for (final profile in actions.profiles())
              PopupMenuItem(
                value: profile,
                height: 32,
                child: Row(
                  children: [
                    const Icon(AppIcons.terminal, size: Chrome.icon),
                    const SizedBox(width: 10),
                    Text(profile.label),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// A chord in a tooltip, or nothing when the action has none.
String _chord(String? label) => label == null ? '' : ' ($label)';

/// The chord that splits along [axis]. Both halves share one intent type, so
/// the axis is what tells `Ctrl+Shift+D` from `Ctrl+Shift+E`.
String? _splitChord(SplitAxis axis) =>
    shellChordLabel<SplitTerminalPaneIntent>(where: (i) => i.axis == axis);

/// The chord that opens quick open filtered to snippets. Four chords share
/// [OpenQuickOpenIntent], so the seeded query is what tells them apart.
String? _snippetChord() =>
    shellChordLabel<OpenQuickOpenIntent>(where: (i) => i.query == r'$');
