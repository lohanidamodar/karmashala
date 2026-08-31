import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_icons.dart';
import '../theme/design_tokens.dart';
import 'quick_open/quick_open_item.dart';
import 'quick_open/quick_open_list.dart';

/// One tab in the workbench strip, as the picker needs it.
///
/// Wraps a [QuickOpenItem] rather than restating one: a tab *is* a findable
/// thing, so it is scored by [scoreItem] and drawn by [QuickOpenRow] like every
/// other row in the shell. Only the two things a result cannot have are added —
/// whether it is the tab on screen, and how to close it.
class TabEntry {
  const TabEntry({required this.item, required this.active, this.onClose});

  final QuickOpenItem item;

  /// Whether this is the tab the workbench is showing.
  final bool active;

  /// Closes the tab from the list. `null` when it cannot be closed from here.
  final VoidCallback? onClose;

  String get id => item.id;
}

/// A ranked entry, with the characters of its title the query matched.
class _Ranked {
  const _Ranked(this.entry, this.positions);

  final TabEntry entry;
  final List<int> positions;
}

/// Every open tab, in one filterable list.
///
/// **Why a list and not just better scrolling.** The app is built for a hundred
/// live terminals (`docs/ARCHITECTURE.md`), and a horizontal strip is hopeless
/// at a hundred tabs however well it scrolls — the answer has to be a way to
/// *find* a tab by name, not a way to travel past ninety-nine of them. So this
/// is the affordance that scales, and the strip's chevrons are the one for
/// mild overflow.
///
/// **Two `zsh` tabs have to be distinguishable.** Each row carries the tab's
/// whereabouts as well as its title — the session running in it, or the
/// directory its pane is in — and the filter matches those too, which is what
/// makes the list usable when every title is the name of a shell.
class TabPicker extends ConsumerStatefulWidget {
  const TabPicker({required this.entries, super.key});

  /// Re-derived on every build from live state, so closing a tab from the list
  /// takes its row away instead of leaving a stale copy behind.
  final List<TabEntry> Function(WidgetRef ref) entries;

  static Future<void> show(
    BuildContext context,
    List<TabEntry> Function(WidgetRef ref) entries,
  ) => showDialog<void>(
    context: context,
    barrierColor: Theme.of(context).colorScheme.scrim.withValues(alpha: 0.35),
    builder: (_) => TabPicker(entries: entries),
  );

  @override
  ConsumerState<TabPicker> createState() => _TabPickerState();
}

class _TabPickerState extends ConsumerState<TabPicker> {
  final _query = TextEditingController();
  final _scroll = ScrollController();

  /// The rows the last build produced, so the key handlers act on exactly what
  /// is on screen.
  List<_Ranked> _rows = const [];
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
    // tab is actually drawn in has to be part of the comparison rather than
    // something the sort is trusted to preserve.
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
  /// open does not: a list that jumps from its last row to its first is one you
  /// cannot hold the arrow key down on.
  void _select(int index) {
    if (_rows.isEmpty) return;
    setState(() => _selected = index.clamp(0, _rows.length - 1));
    _reveal();
  }

  void _reveal() {
    if (!_scroll.hasClients || _rows.isEmpty) return;
    final target = revealOffset(
      position: _scroll.position,
      leading: _selected * quickOpenRowHeight,
      extent: quickOpenRowHeight,
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

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final control = HardwareKeyboard.instance.isControlPressed;
    final key = event.logicalKey;
    // The same bindings quick open has: this is the shell's second filtered
    // list, not a surface with a vocabulary of its own.
    if (key == LogicalKeyboardKey.arrowDown ||
        (control && key == LogicalKeyboardKey.keyN)) {
      _select(_selected + 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp ||
        (control && key == LogicalKeyboardKey.keyP)) {
      _select(_selected - 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.home) {
      _select(0);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.end) {
      _select(_rows.length - 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _activate();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    _rows = _rank(widget.entries(ref));
    if (!_placedCursor && _rows.isNotEmpty) {
      _placedCursor = true;
      final active = _rows.indexWhere((row) => row.entry.active);
      _selected = active < 0 ? 0 : active;
    }
    // Closing the last row leaves the cursor past the end. It stays where the
    // list now ends rather than snapping to the top, so closing a run of tabs
    // from the bottom keeps working without moving the mouse back.
    if (_selected >= _rows.length) _selected = _rows.isEmpty ? 0 : _rows.length - 1;

    return Dialog(
      alignment: Alignment.topCenter,
      insetPadding: const EdgeInsets.only(top: 64, left: 24, right: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 460),
        child: Focus(
          onKeyEvent: _onKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              QuickOpenSearchField(
                controller: _query,
                onChanged: _onQueryChanged,
                hintText: 'Filter tabs by name, session or directory',
              ),
              const Divider(height: 1),
              Flexible(
                child: _rows.isEmpty
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
                        itemExtent: quickOpenRowHeight,
                        itemCount: _rows.length,
                        itemBuilder: (context, index) => _row(index),
                      ),
              ),
              const Divider(height: 1),
              _Footer(count: _rows.length),
            ],
          ),
        ),
      ),
    );
  }

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
          : item.detail,
      selected: index == _selected,
      onTap: () {
        setState(() => _selected = index);
        _activate();
      },
      trailing: onClose == null
          ? null
          : IconButton(
              tooltip: 'Close ${item.title}',
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

class _Footer extends StatelessWidget {
  const _Footer({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: Chrome.statusBar + Insets.xs,
      padding: const EdgeInsets.symmetric(horizontal: Insets.md),
      alignment: Alignment.centerLeft,
      child: DefaultTextStyle.merge(
        style: theme.textTheme.labelSmall!.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
        child: Row(
          children: [
            Text('$count tab${count == 1 ? '' : 's'}'),
            const Spacer(),
            const Flexible(
              child: Text(
                '↑↓ move   ·   Enter switch   ·   Esc close',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
