import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../application/terminal_search_controller.dart';
import '../domain/terminal_search.dart';

/// Find-in-scrollback bar: query field, case and regex toggles, match count and
/// next/previous navigation.
///
/// Enter and Shift+Enter step through matches and Escape closes, all bound here
/// rather than in the terminal's own key handling — while this field has focus
/// the terminal does not, so these never reach the shell.
///
/// Nothing here names a size: the theme's `iconButtonTheme`, `iconTheme` and
/// text styles carry them, so the bar follows the app's text-size setting
/// instead of pinning its own.
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
            Expanded(
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.escape):
                      _search.close,
                  const SingleActivator(LogicalKeyboardKey.enter): _search.next,
                  const SingleActivator(LogicalKeyboardKey.enter, shift: true):
                      _search.previous,
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
                        : 'Find in scrollback',
                  ),
                  onChanged: _search.setQuery,
                ),
              ),
            ),
            _CountLabel(state: state),
            const SizedBox(width: Insets.xs),
            IconButton(
              tooltip: 'Match case',
              isSelected: state.caseSensitive,
              visualDensity: VisualDensity.compact,
              icon: Text('Aa', style: theme.textTheme.labelSmall),
              onPressed: _search.toggleCaseSensitive,
            ),
            IconButton(
              // Named for what it does rather than for the syntax: the tooltip
              // is also where "the case toggle still applies" gets said, since
              // Dart's RegExp has no inline `(?i)` to say it in the pattern.
              tooltip: 'Use regular expression (Match case still applies)',
              isSelected: state.regex,
              visualDensity: VisualDensity.compact,
              icon: Text('.*', style: theme.textTheme.labelSmall),
              onPressed: _search.toggleRegex,
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

class _CountLabel extends StatelessWidget {
  const _CountLabel({required this.state});

  final TerminalSearchState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (state.query.isEmpty) return const SizedBox.shrink();

    // A pattern that does not compile says so instead of reporting "No
    // results", which would read as "your pattern is fine, the text is not
    // there" — the one wrong answer this feature must never give.
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

    final label = state.hasMatches
        ? '${state.currentIndex + 1} / ${state.matchCount}'
        : 'No results';
    return Row(
      children: [
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: state.hasMatches
                ? theme.colorScheme.onSurfaceVariant
                : theme.colorScheme.error,
          ),
        ),
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
