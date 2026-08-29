import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../application/terminal_search_controller.dart';
import '../domain/terminal_search.dart';

/// Find-in-scrollback bar: query field, case toggle, match count and next/
/// previous navigation.
///
/// Enter and Shift+Enter step through matches and Escape closes, all bound here
/// rather than in the terminal's own key handling — while this field has focus
/// the terminal does not, so these never reach the shell.
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
              size: 16,
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
                  style: const TextStyle(fontSize: 13),
                  decoration: const InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: 'Find in scrollback',
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
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              icon: const Text('Aa', style: TextStyle(fontSize: 12)),
              onPressed: _search.toggleCaseSensitive,
            ),
            IconButton(
              tooltip: 'Previous match (Shift+Enter)',
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              icon: const Icon(AppIcons.caretUp),
              onPressed: state.hasMatches ? _search.previous : null,
            ),
            IconButton(
              tooltip: 'Next match (Enter)',
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              icon: const Icon(AppIcons.caretDown),
              onPressed: state.hasMatches ? _search.next : null,
            ),
            IconButton(
              tooltip: 'Close find (Esc)',
              iconSize: 16,
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
