import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../application/overview_board.dart';
import '../application/overview_drawer.dart';
import '../application/overview_family_order.dart';
import '../application/overview_search.dart';
import 'overview_card_parts.dart';
import 'overview_pins.dart';
import 'overview_strip.dart';
import 'overview_triage.dart';

/// **The phone dashboard's bottom bar**, under the thumb: Search (a sheet),
/// Waiting N (the drawer as a sheet), Next new (as U does) and Lanes.
class OverviewPhoneBar extends ConsumerWidget {
  const OverviewPhoneBar({
    required this.waiting,
    required this.fresh,
    required this.onLanes,
    super.key,
  });

  /// How many wait on the owner, and how many sessions are new.
  final int waiting;
  final int fresh;

  /// Brings the lane chips into reach.
  final VoidCallback onLanes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final semantic = SemanticColors.of(context);
    final sheet = ref.watch(overviewSearchSheetProvider);
    final drawer = ref.watch(overviewDrawerProvider.select((d) => d.open));
    // A highlight or a query left on dims the board; the Search item says so.
    final narrowing =
        ref.watch(overviewHighlightProvider) != OverviewHighlight.none ||
        ref.watch(overviewSearchProvider.select((s) => s.active));
    final sheets = ref.read(overviewSearchSheetProvider.notifier);
    final drawers = ref.read(overviewDrawerProvider.notifier);
    return DecoratedBox(
      key: const ValueKey('overview-phone-bar'),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          _BarItem(
            key: const ValueKey('overview-bar-search'),
            icon: AppIcons.magnifyingGlass,
            label: 'Search',
            selected: sheet || narrowing,
            onTap: () {
              drawers.close();
              sheet ? sheets.close() : sheets.open();
            },
          ),
          _BarItem(
            key: const ValueKey('overview-bar-waiting'),
            icon: AppIcons.bellSimple,
            label: 'Waiting',
            count: waiting,
            countColor: semantic.attention,
            selected: drawer,
            onTap: () {
              sheets.close();
              drawers.toggle();
            },
          ),
          _BarItem(
            key: const ValueKey('overview-bar-next-new'),
            icon: AppIcons.star,
            label: 'Next new',
            count: fresh,
            countColor: semantic.unread,
            onTap: () {
              sheets.close();
              FocusManager.instance.primaryFocus?.unfocus();
              Actions.maybeInvoke(context, const OverviewNextNewIntent());
            },
          ),
          _BarItem(
            key: const ValueKey('overview-bar-lanes'),
            icon: AppIcons.list,
            label: 'Lanes',
            onTap: () {
              sheets.close();
              onLanes();
            },
          ),
        ],
      ),
    );
  }
}

/// One of the bar's items: a compact glyph and label in a thumb's target.
class _BarItem extends StatelessWidget {
  const _BarItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
    this.count = 0,
    this.countColor,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;
  final int count;
  final Color? countColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ink = selected ? scheme.primary : scheme.onSurfaceVariant;
    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        label: count > 0 ? '$label, $count' : label,
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: Touch.target),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Insets.xxs,
                vertical: Insets.xs,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Badge(
                    isLabelVisible: count > 0,
                    label: Text('$count'),
                    backgroundColor: countColor,
                    textColor: scheme.surface,
                    child: Icon(icon, size: Touch.icon, color: ink),
                  ),
                  const SizedBox(height: Insets.xxs),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: ink,
                      fontWeight: selected ? FontWeight.w600 : null,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// **The phone's search sheet**, over the board above the bar: the strip's
/// search with New and Pinned as quick filters and the same results list.
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
