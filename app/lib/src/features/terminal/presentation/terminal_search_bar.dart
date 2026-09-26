import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/tokens.dart';
import '../application/terminal_search_controller.dart';
import 'package:karmashala_terminal_core/grid.dart';

/// Find bar. Enter, Shift+Enter and Escape are bound here rather than in the
/// terminal's key handling, because this field has the focus while it is open.
class TerminalSearchBar extends ConsumerStatefulWidget {
  const TerminalSearchBar({super.key});

  @override
  ConsumerState<TerminalSearchBar> createState() => _TerminalSearchBarState();
}

class _TerminalSearchBarState extends ConsumerState<TerminalSearchBar> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  TerminalSearchController get _search =>
      ref.read(terminalSearchControllerProvider.notifier);

  /// Below this width (at 1x text) the three toggles fold into one menu, so
  /// Previous, Next and Close stay on the bar in a narrow split.
  static const _foldTogglesBelow = 420.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = ref.watch(terminalSearchControllerProvider);
    final scaler = MediaQuery.textScalerOf(context);

    return Material(
      color: theme.colorScheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.sm,
          vertical: Insets.xs,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final narrow =
                constraints.maxWidth <
                WidthClass.scaleBreakpoint(_foldTogglesBelow, scaler);
            return Row(
              children: [
                Icon(
                  AppIcons.magnifyingGlass,
                  size: Chrome.icon,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: Insets.sm),
                // Flexed against the jump button below, so a long pane name
                // cannot push the controls off the end of the row.
                Expanded(flex: 3, child: _field(state)),
                Flexible(child: _CountLabel(state: state)),
                const SizedBox(width: Insets.xs),
                if (state.currentIsElsewhere)
                  // Where the selected hit is, and the way there. Stepping
                  // deliberately does not jump — see `revealCurrent`.
                  narrow
                      ? _jumpIcon(state)
                      : Flexible(
                          child: LayoutBuilder(
                            // An icon and a few characters, or just the icon.
                            builder: (context, box) =>
                                box.maxWidth < scaler.scale(_jumpLabelMin)
                                ? _jumpIcon(state)
                                : TextButton.icon(
                                    onPressed: _search.revealCurrent,
                                    icon: const Icon(AppIcons.arrowSquareOut),
                                    label: Text(
                                      state.currentPaneTitle ?? 'Other pane',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                          ),
                        ),
                if (!narrow && state.crossPane && state.query.isNotEmpty)
                  _SweepLabel(state: state),
                if (narrow)
                  _OptionsMenu(state: state, search: _search)
                else ...[
                  IconButton(
                    tooltip: 'Match case',
                    isSelected: state.caseSensitive,
                    visualDensity: VisualDensity.compact,
                    icon: Text('Aa', style: theme.textTheme.labelSmall),
                    onPressed: _search.toggleCaseSensitive,
                  ),
                  IconButton(
                    // The tooltip is where "the case toggle still applies"
                    // gets said, since Dart's RegExp has no inline `(?i)`.
                    tooltip:
                        'Use regular expression (Match case still applies)',
                    isSelected: state.regex,
                    visualDensity: VisualDensity.compact,
                    icon: Text('.*', style: theme.textTheme.labelSmall),
                    onPressed: _search.toggleRegex,
                  ),
                  IconButton(
                    tooltip: 'Search every open pane',
                    isSelected: state.crossPane,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(AppIcons.terminalWindow),
                    onPressed: _search.toggleCrossPane,
                  ),
                ],
                IconButton(
                  tooltip: 'Previous match (Shift+Enter)',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(AppIcons.caretUp),
                  onPressed: state.hasMatches ? _search.previous : null,
                ),
                IconButton(
                  tooltip: 'Next match (Enter)',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(AppIcons.caretDown),
                  onPressed: state.hasMatches ? _search.next : null,
                ),
                IconButton(
                  tooltip: 'Close find (Esc)',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(AppIcons.x),
                  onPressed: _search.close,
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// The least width the jump button is drawn with its pane's name.
  static const _jumpLabelMin = 72.0;

  Widget _jumpIcon(TerminalSearchState state) => IconButton(
    tooltip: state.currentPaneTitle ?? 'Other pane',
    visualDensity: VisualDensity.compact,
    icon: const Icon(AppIcons.arrowSquareOut),
    onPressed: _search.revealCurrent,
  );

  Widget _field(TerminalSearchState state) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _search.close,
        const SingleActivator(LogicalKeyboardKey.enter): _search.next,
        const SingleActivator(LogicalKeyboardKey.enter, shift: true):
            _search.previous,
        const SingleActivator(LogicalKeyboardKey.enter, control: true):
            _search.revealCurrent,
      },
      child: TextField(
        controller: _controller,
        focusNode: _focusNode,
        autofocus: true,
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          hintText: state.regex
              ? 'Find by pattern'
              : state.onAlternateScreen
              ? 'Find on screen'
              : 'Find in scrollback',
        ),
        onChanged: _search.setQuery,
      ),
    );
  }
}

enum _FindOption { matchCase, regex, crossPane }

/// The three toggles as one menu, for a bar too narrow to show them. The glyph
/// fills while any of them is on, so a folded option is not a hidden one.
class _OptionsMenu extends StatelessWidget {
  const _OptionsMenu({required this.state, required this.search});

  final TerminalSearchState state;
  final TerminalSearchController search;

  @override
  Widget build(BuildContext context) {
    final anyOn = state.caseSensitive || state.regex || state.crossPane;
    return PopupMenuButton<_FindOption>(
      tooltip: 'Find options',
      icon: Icon(anyOn ? AppIcons.funnelFill : AppIcons.funnel),
      style: IconButton.styleFrom(visualDensity: VisualDensity.compact),
      itemBuilder: (context) => [
        DesktopMenuItem(
          value: _FindOption.matchCase,
          label: 'Match case',
          icon: AppIcons.circle,
          selected: state.caseSensitive,
        ),
        DesktopMenuItem(
          value: _FindOption.regex,
          label: 'Use regular expression',
          icon: AppIcons.circle,
          selected: state.regex,
        ),
        DesktopMenuItem(
          value: _FindOption.crossPane,
          label: 'Search every open pane',
          icon: AppIcons.terminalWindow,
          selected: state.crossPane,
        ),
      ],
      onSelected: (option) => switch (option) {
        _FindOption.matchCase => search.toggleCaseSensitive(),
        _FindOption.regex => search.toggleRegex(),
        _FindOption.crossPane => search.toggleCrossPane(),
      },
    );
  }
}

/// How far the cross-pane sweep got. Panes left over with nothing still running
/// means it hit its match budget — a partial answer, and it has to look like
/// one.
class _SweepLabel extends StatelessWidget {
  const _SweepLabel({required this.state});

  final TerminalSearchState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (state.panesPending == 0 && !state.scanning) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
        child: Text(
          '${state.panesSearched} panes',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    final total = state.panesSearched + state.panesPending;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
      child: Tooltip(
        message: state.scanning
            ? 'Reading the other panes a pane at a time, so the terminal '
                  'keeps its frames.'
            : 'Stopped at $kCrossPaneMatchBudget matches. Narrow the query to '
                  'reach the rest.',
        child: Text(
          '${state.panesSearched} of $total panes',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontStyle: FontStyle.italic,
          ),
        ),
      ),
    );
  }
}

class _CountLabel extends StatelessWidget {
  const _CountLabel({required this.state});

  final TerminalSearchState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (state.query.isEmpty) return const SizedBox.shrink();
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontStyle: FontStyle.italic,
    );

    // A pattern that does not compile says so rather than "No results", which
    // would read as "your pattern is fine, the text is not there".
    final error = state.patternError;
    if (error != null) {
      return Tooltip(
        message: error,
        child: Text(
          'Invalid pattern',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
      );
    }

    final hidden = state.hiddenScrollbackMatches;
    final label = state.hasMatches
        ? '${state.currentIndex + 1} / ${state.matchCount}'
        : hidden > 0
        ? 'None on screen'
        : 'No results';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: state.hasMatches || hidden > 0
                  ? theme.colorScheme.onSurfaceVariant
                  : theme.colorScheme.error,
            ),
          ),
        ),
        // Without this a full-screen program turns a pane's whole history into
        // "No results".
        if (hidden > 0) ...[
          const SizedBox(width: Insets.xs),
          Flexible(
            child: Tooltip(
              message:
                  'The scrollback is behind the full-screen program using '
                  'this pane. Quit it to search and scroll to those matches.',
              child: Text(
                '+$hidden behind',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: muted,
              ),
            ),
          ),
        ],
        if (state.truncated) ...[
          const SizedBox(width: Insets.xs),
          Flexible(
            child: Tooltip(
              message:
                  'Only the first $kMaxSearchHighlights matches are '
                  'highlighted; navigation still reaches them all.',
              child: Text(
                'first $kMaxSearchHighlights shown',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: muted,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
