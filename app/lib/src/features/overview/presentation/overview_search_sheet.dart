import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/shell/quick_open/quick_open.dart';
import '../application/overview_board.dart';
import '../application/overview_drawer.dart';
import '../application/overview_family_order.dart';
import '../application/overview_search.dart';
import 'overview_card_parts.dart';
import 'overview_pins.dart';
import 'overview_strip.dart';

/// **The phone's search sheet**, over the board, opened from the top bar's
/// search on the Dashboard: the strip's search with New and Pinned as quick
/// filters and the same results list, and a way on to quick open.
/// A pick shows the session on the board and closes the sheet.
class OverviewSearchSheet extends ConsumerStatefulWidget {
  const OverviewSearchSheet({required this.queue, super.key});

  /// What waits on the owner, in the drawer's order.
  final List<OverviewCard> queue;

  @override
  ConsumerState<OverviewSearchSheet> createState() =>
      _OverviewSearchSheetState();
}

class _OverviewSearchSheetState extends ConsumerState<OverviewSearchSheet> {
  final _controller = TextEditingController();
  var _ids = const <String>[];

  @override
  void initState() {
    super.initState();
    _controller.text = ref.read(overviewSearchProvider).query;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Shows [id] on the board; the query goes, as nothing on a phone's board
  /// would show it.
  void _pick(String id) {
    ref.read(overviewRevealProvider.notifier).reveal(id);
    _close();
  }

  void _close() {
    ref.read(overviewSearchProvider.notifier).clear();
    ref.read(overviewSearchSheetProvider.notifier).close();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(overviewSearchProvider.select((s) => s.query), (_, query) {
      if (_controller.text != query) _controller.text = query;
    });
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final search = ref.watch(overviewSearchProvider);
    final forest = ref.watch(overviewForestProvider);
    final highlight = ref.watch(overviewHighlightProvider);
    final lit = ref.read(overviewHighlightProvider.notifier);
    final pinnedIds = {for (final card in watchOverviewPinned(ref)) card.id};
    final pinnedMembers = {
      ...pinnedIds,
      for (final (_, trees) in forest.lanes)
        for (final tree in trees)
          if (tree.drawn.any((c) => pinnedIds.contains(c.id)))
            for (final card in tree.drawn) card.id,
    };
    bool keep(OverviewCard card) => switch (highlight) {
      OverviewHighlight.none => true,
      OverviewHighlight.fresh => watchOverviewNewCount(ref, card) > 0,
      OverviewHighlight.pinned => pinnedMembers.contains(card.id),
    };
    final fresh = [
      for (final card in overviewForestMembers(forest))
        if (watchOverviewNewCount(ref, card) > 0) card,
    ].length;
    final List<(String, List<OverviewCard>)> base;
    if (search.active) {
      final matches = watchOverviewSearchMatches(ref, forest);
      base = [
        (
          '${matches.length} ${matches.length == 1 ? 'match' : 'matches'}',
          [...matches],
        ),
      ];
    } else if (highlight == OverviewHighlight.pinned) {
      base = [
        (
          'Pinned',
          [
            for (final card in overviewForestMembers(forest))
              if (pinnedMembers.contains(card.id)) card,
          ],
        ),
      ];
    } else {
      base = watchOverviewSearchHints(ref, forest, widget.queue);
    }
    final sections = [
      for (final (title, cards) in base)
        if (cards.where(keep).toList() case final kept when kept.isNotEmpty)
          (title, kept),
    ];
    _ids = [
      for (final (_, cards) in sections)
        for (final card in cards) card.id,
    ];
    return Material(
      key: const ValueKey('overview-search-sheet'),
      color: scheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Insets.sm,
              Insets.sm,
              Insets.xxs,
              Insets.xs,
            ),
            child: Row(
              children: [
                Expanded(
                  child: SearchField(
                    key: const ValueKey('overview-search-sheet-field'),
                    controller: _controller,
                    autofocus: true,
                    decoration: compactSearchDecoration(
                      hintText: 'Search sessions',
                    ),
                    onChanged: ref.read(overviewSearchProvider.notifier).type,
                    onSubmitted: (_) {
                      final to = search.current ?? _ids.firstOrNull;
                      if (to != null) _pick(to);
                    },
                  ),
                ),
                IconButton(
                  key: const ValueKey('overview-search-sheet-everything'),
                  tooltip: 'Search everything',
                  onPressed: () {
                    unawaited(
                      QuickOpen.show(context, initialQuery: _controller.text),
                    );
                    _close();
                  },
                  icon: const Icon(AppIcons.listMagnifyingGlass),
                ),
                IconButton(
                  key: const ValueKey('overview-search-sheet-close'),
                  tooltip: 'Close search',
                  onPressed: _close,
                  icon: const Icon(AppIcons.x),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Insets.sm,
              0,
              Insets.sm,
              Insets.sm,
            ),
            child: Wrap(
              spacing: Insets.xs,
              runSpacing: Insets.xs,
              children: [
                OverviewStripToggle(
                  key: const ValueKey('overview-search-sheet-new'),
                  label: 'New · $fresh',
                  selected: highlight == OverviewHighlight.fresh,
                  onTap: () => lit.toggle(OverviewHighlight.fresh),
                ),
                OverviewStripToggle(
                  key: const ValueKey('overview-search-sheet-pinned'),
                  label: 'Pinned',
                  icon: AppIcons.pushPin,
                  selected: highlight == OverviewHighlight.pinned,
                  onTap: () => lit.toggle(OverviewHighlight.pinned),
                ),
              ],
            ),
          ),
          const Divider(height: Insets.hair),
          Expanded(
            child: sections.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(Insets.lg),
                    child: Text(
                      search.active
                          ? 'No session matches "${search.query.trim()}".'
                          : 'Nothing needs you and nothing is new. Type to '
                                'search every session.',
                      key: const ValueKey('overview-search-sheet-empty'),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : OverviewSearchResults(
                    sections: sections,
                    current: search.current,
                    onPick: _pick,
                    sheet: true,
                  ),
          ),
        ],
      ),
    );
  }
}
