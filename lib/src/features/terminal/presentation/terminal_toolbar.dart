// **The group's own toolbar**, and the three chord lookups its tooltips are
// written with — find, the snippets, the two workspace splits, the new
// terminal and the profile caret beside it.
//
// A part of `terminal_panel.dart` rather than a library of its own, even
// though `TerminalToolbar` is public: `_chord` and its two narrowing helpers
// are private and `_NoTerminalOpen` spells its own button's chord with them,
// so the three of them and the two widgets that read them have to share one
// library. A part is how they do that without a rename, and a rename is
// exactly what the tree golden would record.

part of 'terminal_panel.dart';

/// One workspace group's own toolbar — find, split, new tab, and the recorded
/// commands button that only appears when it has something to say.
///
/// Sits at the right of that group's tab strip, so a verb that acts on *this*
/// group's focused pane is beside that group's tabs. What is **not** here any
/// more is what was never about one group: the restored-session and
/// background-session badges are questions about the window, and they have
/// gone up to the title bar with focus mode. See [ShellTitleBar].
class TerminalToolbar extends ConsumerWidget {
  const TerminalToolbar({this.compact = false, super.key});

  /// Only the way to make another terminal, for a window too narrow to hold the
  /// rest of the row.
  ///
  /// The other five are a chord and a palette command each, and the two splits
  /// are on the pane's own menu as well — but **the `+` must never be off
  /// screen**. That was true when this row lived in the tab strip ("no number
  /// of tabs can push the way to make another one off the end") and moving the
  /// row up did not stop it being true.
  final bool compact;

  /// Builds of this widget, for `snippet_button_cost_test.dart`.
  ///
  /// The same seam `ShellStatusBar.debugItemBuildCount` and
  /// `ModelChip.debugBuildCount` use, and here for the same reason: this row
  /// sits above a terminal somebody types into all day, and the only way to
  /// keep proving it does not wake for a character is to count it.
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
        // The saved commands, for whichever pane is in front. Deliberately
        // **unconditional**: it never asks how many snippets there are, so the
        // strip takes out no subscription that a write to the library — or
        // anything else happening while somebody types — could wake. The empty
        // case is answered inside the picker, which always offers "New command
        // snippet…". See `snippet_button_cost_test.dart`.
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
          // chrome; a split is its own shape, and the vertical one no longer
          // needs a RotatedBox to be drawn.
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
        // Two controls, the way VS Code splits them: the button opens the
        // shell you nearly always want, and the caret beside it is where the
        // other ones live. One button that could only ever open a menu made
        // the common case cost a choice.
        IconButton(
          tooltip: 'New terminal${_chord(shellChordLabel<NewTerminalTabIntent>())}',
          icon: const Icon(AppIcons.plus, size: Chrome.icon),
          onPressed: () => actions.open(actions.defaultProfile()),
        ),
        PopupMenuButton<TerminalProfile>(
          tooltip: 'New terminal with a different profile',
          icon: const Icon(AppIcons.caretDown, size: Chrome.iconSmall),
          // The caret is a hair beside the +, not a second button's width away.
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

/// The chord that opens quick open already filtered to snippets. Four chords
/// share [OpenQuickOpenIntent], so the seeded query is what tells them apart —
/// the same narrowing the two split chords need.
String? _snippetChord() =>
    shellChordLabel<OpenQuickOpenIntent>(where: (i) => i.query == r'$');
