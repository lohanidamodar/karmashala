import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../widgets/adaptive_modal.dart';
import 'quick_open/quick_open_item.dart';
import 'quick_open/quick_open_list.dart';

/// One tab in the workbench strip, as the picker needs it. Wraps a
/// [QuickOpenItem] so a tab is scored and drawn like every other row.
class TabEntry {
  const TabEntry({
    required this.item,
    required this.active,
    this.unsaved = false,
    this.running,
    this.onClose,
  });

  final QuickOpenItem item;

  /// Whether this is the tab the workbench is showing.
  final bool active;

  /// Whether it holds a file with edits that are not on disk — said here too,
  /// because this list offers to close it.
  final bool unsaved;

  /// Whether a process runs in it. Null for a tab with no process — a
  /// document — which keeps its place; false folds it under "Not running".
  final bool? running;

  /// Closes the tab from the list. `null` when it cannot be closed from here.
  final VoidCallback? onClose;

  String get id => item.id;

  /// Folded under "Not running" — never the tab you are in.
  bool get _idle => running == false && !active;
}

/// A ranked entry, with the characters of its title the query matched.
class _Ranked {
  const _Ranked(this.entry, this.positions);

  final TabEntry entry;
  final List<int> positions;
}

/// Every open tab, in one filterable list — the affordance that scales where a
/// horizontal strip does not. Rows carry whereabouts, so two `zsh` tabs differ.
/// Tabs whose process is not running fold under one row at the end.
class TabPicker extends ConsumerStatefulWidget {
  const TabPicker({required this.entries, this.inSheet = false, super.key});

  /// Re-derived on every build from live state, so closing a tab from the list
  /// takes its row away instead of leaving a stale copy behind.
  final List<TabEntry> Function(WidgetRef ref) entries;

  /// Drawn as a bottom sheet's body rather than as its own dialog.
  final bool inSheet;

  static const closeIdleTooltip =
      'Close all not running: closes these tabs only. No session is ended or '
      'archived.';

  /// A bottom sheet on a compact window, as the phone's other pickers are; the
  /// quick-open dialog elsewhere.
  static Future<void> show(
    BuildContext context,
    List<TabEntry> Function(WidgetRef ref) entries,
  ) {
    if (WidthClass.of(MediaQuery.sizeOf(context).width).isCompact) {
      return showAdaptiveModal<void>(
        context: context,
        title: 'Tabs',
        heightFactor: 0.7,
        builder: (_) => TabPicker(entries: entries, inSheet: true),
      );
    }
    return showDialog<void>(
      context: context,
      barrierColor: Theme.of(context).colorScheme.scrim.withValues(alpha: 0.35),
      builder: (_) => TabPicker(entries: entries),
    );
  }

  @override
  ConsumerState<TabPicker> createState() => _TabPickerState();
}

class _TabPickerState extends ConsumerState<TabPicker> {
  final _query = TextEditingController();
  final _scroll = ScrollController();

  /// The rows the last build made selectable, in drawn order, so the key
  /// handlers act on exactly what is on screen.
  List<_Ranked> _rows = const [];

  /// The rows folded under "Not running", whether or not they are shown.
  List<_Ranked> _idle = const [];

  /// Where the "Not running" row is drawn, or null when there is none.
  int? _foldAt;
  bool _unfolded = false;
  int _selected = 0;

  /// The cursor starts on the tab you are already in, so Enter is a no-op and
  /// one arrow press is the next tab — not a jump to the top of the list.
  bool _placedCursor = false;

  @override
  void dispose() {
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<_Ranked> _rank(List<TabEntry> entries) {
    final query = _query.text.trim();
    if (query.isEmpty) {
      return [for (final entry in entries) _Ranked(entry, const [])];
    }
    final scored = <({_Ranked row, double score, int order})>[];
    for (var i = 0; i < entries.length; i++) {
      final result = scoreItem(query, entries[i].item);
      if (result == null) continue;
      scored.add((
        row: _Ranked(entries[i], result.titlePositions),
        score: result.score,
        order: i,
      ));
    }
    // Strip order breaks a tie — `List.sort` is not stable, so the position a
    // tab is drawn in has to be part of the comparison.
    scored.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      return byScore != 0 ? byScore : a.order.compareTo(b.order);
    });
    return [for (final entry in scored) entry.row];
  }

  void _onQueryChanged(String _) {
    setState(() => _selected = 0);
    // The extents still describe the previous list until it has been laid out.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reveal();
    });
  }

  /// Moves the cursor to [index], clamped. Does not wrap, for the reason quick
  /// open does not: a list you cannot hold the arrow key down on.
  void _select(int index) {
    if (_rows.isEmpty) return;
    setState(() => _selected = index.clamp(0, _rows.length - 1));
    _reveal();
  }

  /// Where row [index] is drawn: one further down past the fold row.
  int _lineOf(int index) {
    final fold = _foldAt;
    return fold != null && index >= fold ? index + 1 : index;
  }

  void _reveal() {
    if (!_scroll.hasClients || _rows.isEmpty) return;
    final target = revealOffset(
      position: _scroll.position,
      leading: _lineOf(_selected) * quickOpenRowHeightOf(context),
      extent: quickOpenRowHeightOf(context),
    );
    if (target != null) _scroll.jumpTo(target);
  }

  void _activate() {
    if (_rows.isEmpty) return;
    final entry = _rows[_selected].entry;
    Navigator.of(context).pop();
    entry.item.onSelect();
  }

  void _close(TabEntry entry) {
    entry.onClose?.call();
    // The entries are re-derived on the next build; hold the cursor where it
    // was so closing a run of tabs does not send it back to the top.
    setState(() {});
  }

  void _closeIdle() {
    for (final row in _idle) {
      row.entry.onClose?.call();
    }
    setState(() {});
  }

  /// The same bindings quick open has: this is the shell's second filtered
  /// list, not a surface with a vocabulary of its own.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) => handleListNavigation(
    event,
    onMove: (delta) => _select(_selected + delta),
    onHome: () => _select(0),
    onEnd: () => _select(_rows.length - 1),
    onActivate: _activate,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ranked = _rank(widget.entries(ref));
    final filtering = _query.text.trim().isNotEmpty;
    _idle = [
      for (final row in ranked)
        if (row.entry._idle) row,
    ];
    final shown = [
      for (final row in ranked)
        if (!row.entry._idle) row,
    ];
    _foldAt = _idle.isEmpty ? null : shown.length;
    // A filter reaches folded rows: what is typed is looked for everywhere.
    final unfolded = _unfolded || filtering;
    _rows = [...shown, if (unfolded) ..._idle];
    if (!_placedCursor && _rows.isNotEmpty) {
      _placedCursor = true;
      final active = _rows.indexWhere((row) => row.entry.active);
      _selected = active < 0 ? 0 : active;
    }
    // Closing the last row leaves the cursor past the end. It stays where the
    // list now ends rather than snapping to the top.
    if (_selected >= _rows.length) {
      _selected = _rows.isEmpty ? 0 : _rows.length - 1;
    }

    final count = ranked.length;
    // Under touch, focus raises a keyboard over the list being picked from.
    final touch = UiDensity.of(context).isTouch;
    final searchField = QuickOpenSearchField(
      controller: _query,
      onChanged: _onQueryChanged,
      hintText: 'Filter tabs by name, session or directory',
      autofocus: !touch,
    );
    final body = ranked.isEmpty
        ? Padding(
            padding: const EdgeInsets.all(Insets.xl),
            child: Text(
              'No tab matches.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          )
        : ListView.builder(
            controller: _scroll,
            padding: EdgeInsets.zero,
            itemExtent: quickOpenRowHeightOf(context),
            itemCount: _rows.length + (_foldAt == null ? 0 : 1),
            itemBuilder: (context, line) {
              final fold = _foldAt;
              if (line == fold) return _foldRow(unfolded, filtering);
              return _row(fold != null && line > fold ? line - 1 : line);
            },
          );
    final footer = QuickOpenFooter(
      leading: Text('$count tab${count == 1 ? '' : 's'}'),
      // Keys mean nothing to a thumb.
      hint: touch ? '' : '↑↓ move   ·   Enter switch   ·   Esc close',
    );
    if (!widget.inSheet) {
      return QuickOpenFrame(
        maxWidth: 560,
        maxHeight: 460,
        onKey: _onKey,
        searchField: searchField,
        body: body,
        footer: footer,
      );
    }
    final rule = Divider(
      height: 1,
      thickness: 1,
      color: SurfaceTones.of(context).floatingLine,
    );
    return Focus(
      onKeyEvent: _onKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          searchField,
          rule,
          Expanded(child: body),
          rule,
          footer,
        ],
      ),
    );
  }

  /// "Not running · N": opens and folds the rows under it, and offers to
  /// close them all. Unfolded while a filter is typed, so it cannot fold.
  Widget _foldRow(bool unfolded, bool filtering) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final closable = _idle.any((row) => row.entry.onClose != null);
    final label = theme.textTheme.labelSmall
        ?.merge(Chrome.groupLabel)
        .copyWith(color: muted);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              button: true,
              expanded: unfolded,
              child: InkWell(
                borderRadius: BorderRadius.circular(Radii.sm),
                onTap: filtering
                    ? null
                    : () => setState(() => _unfolded = !_unfolded),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
                  child: Row(
                    children: [
                      Icon(
                        unfolded ? AppIcons.caretDown : AppIcons.caretRight,
                        size: Chrome.iconSmall,
                        color: muted,
                      ),
                      const SizedBox(width: Insets.sm),
                      Flexible(
                        child: Text(
                          'Not running · ${_idle.length}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: label,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (closable)
            Flexible(
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: LayoutBuilder(
                  builder: (context, constraints) => Tooltip(
                    message: TabPicker.closeIdleTooltip,
                    child: TextButton(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        minimumSize: const Size(0, Chrome.row),
                        padding: const EdgeInsets.symmetric(
                          horizontal: Insets.sm,
                        ),
                        textStyle: theme.textTheme.labelMedium,
                      ),
                      onPressed: _closeIdle,
                      // The row already says "Not running" where the whole
                      // name will not fit — a phone at large text.
                      child: Text(
                        constraints.maxWidth >=
                                MediaQuery.textScalerOf(
                                  context,
                                ).scale(_closeIdleFullWidth)
                            ? 'Close all not running'
                            : 'Close all',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// The width "Close all not running" needs at 1.0 text.
  static const _closeIdleFullWidth = 150.0;

  Widget _row(int index) {
    final row = _rows[index];
    final entry = row.entry;
    final item = entry.item;
    final onClose = entry.onClose;
    return QuickOpenRow(
      icon: item.icon,
      title: item.title,
      titlePositions: row.positions,
      subtitle: item.subtitle,
      // "current" is what tells you where you already are; the row's own
      // highlight is the keyboard cursor and means something else.
      detail: entry.active
          ? (item.detail == null ? 'current' : 'current · ${item.detail}')
          : entry.unsaved
          ? (item.detail == null ? 'unsaved' : 'unsaved · ${item.detail}')
          : item.detail,
      selected: index == _selected,
      onTap: () {
        setState(() => _selected = index);
        _activate();
      },
      trailing: onClose == null
          ? null
          : IconButton(
              tooltip: entry.unsaved
                  ? 'Unsaved changes — close ${item.title}'
                  : 'Close ${item.title}',
              iconSize: Chrome.iconSmall,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(
                minWidth: Chrome.row,
                minHeight: Chrome.row,
              ),
              padding: EdgeInsets.zero,
              icon: const Icon(AppIcons.x),
              onPressed: () => _close(entry),
            ),
    );
  }
}
