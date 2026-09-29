import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

/// One choice in a [FilterMenuField].
class FilterMenuEntry<T> {
  const FilterMenuEntry({
    required this.value,
    required this.label,
    this.detail,
    this.icon,
  });

  final T value;
  final String label;

  /// A second, quieter line: where a worktree is, what a branch tracks.
  final String? detail;
  final IconData? icon;

  /// Whether [query] (already lower-cased) is in the label or the detail.
  bool matches(String query) =>
      query.isEmpty ||
      label.toLowerCase().contains(query) ||
      (detail?.toLowerCase().contains(query) ?? false);
}

/// A form field that opens a menu of [entries] — with a filter field on top
/// once there are more than [filterAfter], as a repository's branches can be
/// hundreds.
///
/// A menu rather than [DropdownButtonFormField]: a dropdown route can hold no
/// text field to narrow it. Safe inside an [AlertDialog], which sizes its body
/// by intrinsics: the field is an [InputDecorator], and the menu's list sits in
/// a box of fixed width and height, so the menu panel's own intrinsic sizing
/// never has to measure a scrolling list — no LayoutBuilder anywhere.
class FilterMenuField<T> extends StatefulWidget {
  const FilterMenuField({
    required this.label,
    required this.entries,
    required this.selected,
    required this.onSelected,
    this.enabled = true,
    this.filterHint = 'Filter',
    this.emptyLabel = 'Nothing to choose',
    this.filterAfter = 8,
    super.key,
  });

  final String label;
  final List<FilterMenuEntry<T>> entries;

  /// The entry drawn in the field; none matching draws [emptyLabel].
  final T selected;
  final ValueChanged<T> onSelected;
  final bool enabled;
  final String filterHint;
  final String emptyLabel;
  final int filterAfter;

  @override
  State<FilterMenuField<T>> createState() => _FilterMenuFieldState<T>();
}

class _FilterMenuFieldState<T> extends State<FilterMenuField<T>> {
  final _menu = MenuController();
  final _filter = TextEditingController();
  final _filterFocus = FocusNode();

  /// The menu is as wide as a narrow dialog's body, whatever half of a row the
  /// field sits in: branch names are long, and a field-wide menu cut them.
  static const double _panelWidth = DialogWidth.narrow - Insets.xxl * 2;

  /// Rows shown before the list scrolls.
  static const int _visibleRows = 8;

  @override
  void dispose() {
    _filter.dispose();
    _filterFocus.dispose();
    super.dispose();
  }

  bool get _filterable => widget.entries.length > widget.filterAfter;

  FilterMenuEntry<T>? get _current {
    for (final entry in widget.entries) {
      if (entry.value == widget.selected) return entry;
    }
    return null;
  }

  void _pick(T value) {
    _menu.close();
    widget.onSelected(value);
  }

  void _toggle() {
    if (!widget.enabled) return;
    if (_menu.isOpen) {
      _menu.close();
      return;
    }
    _filter.clear();
    _menu.open();
  }

  @override
  Widget build(BuildContext context) {
    final current = _current;
    return MenuAnchor(
      controller: _menu,
      // Focus the filter once the panel is in the tree, so typing narrows
      // straight away.
      onOpen: () {
        if (_filterable) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _menu.isOpen) _filterFocus.requestFocus();
          });
        }
      },
      menuChildren: [_panel(context)],
      builder: (context, controller, _) => InkWell(
        onTap: widget.enabled ? _toggle : null,
        borderRadius: BorderRadius.circular(Radii.sm),
        child: InputDecorator(
          isEmpty: false,
          decoration: InputDecoration(
            labelText: widget.label,
            enabled: widget.enabled,
            suffixIcon: const Icon(AppIcons.caretDown, size: Chrome.iconAction),
          ),
          child: Text(
            current?.label ?? widget.emptyLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }

  Widget _panel(BuildContext context) {
    final theme = Theme.of(context);
    // Two lines of text per row, so the row grows with the text scale; never
    // under a thumb's target.
    final extent = math.max(
      MediaQuery.textScalerOf(context).scale(Chrome.menuRowTall),
      UiDensity.of(context).minRow,
    );
    // A phone may be narrower than the panel.
    final room = MediaQuery.sizeOf(context).width - Insets.lg * 2;
    return SizedBox(
      width: math.min(_panelWidth, room),
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: _filter,
        builder: (context, typed, _) {
          final query = typed.text.trim().toLowerCase();
          final matches = [
            for (final entry in widget.entries)
              if (entry.matches(query)) entry,
          ];
          final rows = math.min(math.max(matches.length, 1), _visibleRows);
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_filterable)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Insets.sm,
                    Insets.xs,
                    Insets.sm,
                    Insets.xs,
                  ),
                  child: TextField(
                    controller: _filter,
                    focusNode: _filterFocus,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: widget.filterHint,
                      prefixIcon: const Icon(
                        AppIcons.magnifyingGlass,
                        size: Chrome.iconAction,
                      ),
                    ),
                    // Enter takes the first match, the one a person typed
                    // towards.
                    onSubmitted: (_) {
                      if (matches.isNotEmpty) _pick(matches.first.value);
                    },
                  ),
                ),
              SizedBox(
                height: rows * extent,
                child: matches.isEmpty
                    ? Center(
                        child: Text(
                          'Nothing matches "${typed.text.trim()}".',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : ListView.builder(
                        itemExtent: extent,
                        itemCount: matches.length,
                        itemBuilder: (context, i) => _row(context, matches[i]),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _row(BuildContext context, FilterMenuEntry<T> entry) {
    final theme = Theme.of(context);
    final chosen = entry.value == widget.selected;
    final detail = entry.detail;
    return InkWell(
      onTap: () => _pick(entry.value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Insets.md),
        child: Row(
          children: [
            Icon(
              entry.icon ?? AppIcons.gitBranch,
              size: Chrome.iconAction,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: Insets.sm),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                  if (detail != null)
                    Text(
                      detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            if (chosen)
              Icon(
                AppIcons.check,
                size: Chrome.iconAction,
                color: theme.colorScheme.primary,
              ),
          ],
        ),
      ),
    );
  }
}
