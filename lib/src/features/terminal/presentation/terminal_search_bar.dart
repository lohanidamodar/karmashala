import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../application/terminal_search_controller.dart';
import '../domain/pane_search.dart';
import '../domain/terminal_search.dart';

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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = ref.watch(terminalSearchControllerProvider);

    return Material(
      color: theme.colorScheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.sm,
          vertical: Insets.xs,
        ),
        child: Row(
          children: [
            Icon(
              AppIcons.magnifyingGlass,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: Insets.sm),
            // Flexed against the jump button below, so a long pane name cannot
            // push the controls off the end of the row.
            Expanded(
              flex: 3,
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.escape):
                      _search.close,
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
              ),
            ),
            _CountLabel(state: state),
            const SizedBox(width: Insets.xs),
            if (state.currentIsElsewhere)
              // Where the selected hit is, and the way there. Stepping
              // deliberately does not jump — see `revealCurrent`.
              Flexible(
                child: TextButton.icon(
                  onPressed: _search.revealCurrent,
                  icon: const Icon(AppIcons.arrowSquareOut),
                  label: Text(
                    state.currentPaneTitle ?? 'Other pane',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            if (state.crossPane && state.query.isNotEmpty)
              _SweepLabel(state: state),
            IconButton(
              tooltip: 'Match case',
              isSelected: state.caseSensitive,
              visualDensity: VisualDensity.compact,
              icon: Text('Aa', style: theme.textTheme.labelSmall),
              onPressed: _search.toggleCaseSensitive,
            ),
            IconButton(
              // The tooltip is where "the case toggle still applies" gets
              // said, since Dart's RegExp has no inline `(?i)`.
              tooltip: 'Use regular expression (Match case still applies)',
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
        ),
      ),
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

    // A pattern that does not compile says so rather than "No results", which
    // would read as "your pattern is fine, the text is not there".
    final error = state.patternError;
    if (error != null) {
      return Tooltip(
        message: error,
        child: Text(
          'Invalid pattern',
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
      children: [
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: state.hasMatches || hidden > 0
                ? theme.colorScheme.onSurfaceVariant
                : theme.colorScheme.error,
          ),
        ),
        // Without this a full-screen program turns a pane's whole history into
        // "No results".
        if (hidden > 0) ...[
          const SizedBox(width: Insets.xs),
          Tooltip(
            message:
                'The scrollback is behind the full-screen program using this '
                'pane. Quit it to search and scroll to those matches.',
            child: Text(
              '+$hidden behind',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ],
        if (state.truncated) ...[
          const SizedBox(width: Insets.xs),
          Tooltip(
            message:
                'Only the first $kMaxSearchHighlights matches are highlighted; '
                'navigation still reaches them all.',
            child: Text(
              'first $kMaxSearchHighlights shown',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
