import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_icons.dart';
import 'design_tokens.dart';
import 'search_field.dart';

/// A log view's find field: Enter and Shift+Enter step through matches, Esc
/// hands back to [onEscape]. Stateless — the caller owns text and focus.
class LogSearchField extends StatelessWidget {
  const LogSearchField({
    required this.controller,
    required this.onChanged,
    this.focusNode,
    this.hintText = 'Search logs',
    this.onNext,
    this.onPrevious,
    this.onEscape,
    super.key,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final String hintText;
  final ValueChanged<String> onChanged;
  final VoidCallback? onNext;
  final VoidCallback? onPrevious;
  final VoidCallback? onEscape;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter): ?onNext,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): ?onNext,
        const SingleActivator(LogicalKeyboardKey.enter, shift: true):
            ?onPrevious,
        const SingleActivator(LogicalKeyboardKey.escape): ?onEscape,
      },
      child: SearchField(
        controller: controller,
        clearOnEscape: onEscape == null ? null : false,
        focusNode: focusNode,
        style: theme.textTheme.bodySmall,
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          hintText: hintText,
          prefixIcon: Icon(
            AppIcons.magnifyingGlass,
            size: Chrome.iconAction,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          prefixIconConstraints: const BoxConstraints(
            minWidth: Chrome.icon + Insets.sm,
          ),
        ),
        onChanged: onChanged,
      ),
    );
  }
}

/// "3 of 12", "12 matches", "No matches" or "Invalid pattern" — said inline,
/// with the compiler's reason as the tooltip. Nothing while there is no query.
class LogMatchCount extends StatelessWidget {
  const LogMatchCount({
    required this.hasQuery,
    required this.total,
    this.current,
    this.error,
    super.key,
  });

  final bool hasQuery;
  final int total;

  /// Zero-based index of the selected match, or null.
  final int? current;
  final String? error;

  static String describe({
    required bool hasQuery,
    required int total,
    int? current,
    String? error,
  }) {
    if (!hasQuery) return '';
    if (error != null) return 'Invalid pattern';
    if (total == 0) return 'No matches';
    if (current == null) return total == 1 ? '1 match' : '$total matches';
    return '${current + 1} of $total';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = describe(
      hasQuery: hasQuery,
      total: total,
      current: current,
      error: error,
    );
    if (label.isEmpty) return const SizedBox.shrink();
    final text = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.labelSmall?.copyWith(
        color: error != null || total == 0
            ? theme.colorScheme.error
            : theme.colorScheme.onSurfaceVariant,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
    return error == null ? text : Tooltip(message: error!, child: text);
  }
}

/// A multi-select source filter with its line count.
class LogFilterChip extends StatelessWidget {
  const LogFilterChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.onSelected,
    this.tooltip,
    super.key,
  });

  final String label;
  final int count;
  final bool selected;
  final ValueChanged<bool> onSelected;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chip = FilterChip(
      label: Text('$label $count'),
      labelStyle: theme.textTheme.labelSmall,
      selected: selected,
      showCheckmark: false,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      labelPadding: const EdgeInsets.symmetric(horizontal: Insets.xs),
      padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
      onSelected: onSelected,
    );
    return tooltip == null ? chip : Tooltip(message: tooltip!, child: chip);
  }
}

/// [text] as spans, with each `[start, end)` in [ranges] on a state-layer
/// fill — [currentFill] for the selected line's matches.
TextSpan highlightLogMatches(
  String text,
  List<(int, int)> ranges, {
  required ColorScheme scheme,
  TextStyle? style,
  bool current = false,
}) {
  if (ranges.isEmpty) return TextSpan(text: text, style: style);
  final fill = current
      ? StateLayers.textSelection(scheme)
      : StateLayers.selected(scheme);
  final children = <TextSpan>[];
  var at = 0;
  for (final (start, end) in ranges) {
    if (start < at || end > text.length) continue;
    if (start > at) children.add(TextSpan(text: text.substring(at, start)));
    children.add(
      TextSpan(
        text: text.substring(start, end),
        style: TextStyle(backgroundColor: fill),
      ),
    );
    at = end;
  }
  if (at < text.length) children.add(TextSpan(text: text.substring(at)));
  return TextSpan(style: style, children: children);
}
