// The dashboard, its overview and the card grid.

part of '../stores_tab_view.dart';

/// The overview and the selected app's detail: beside it at expanded width,
/// in its place below it.
class _Dashboard extends ConsumerWidget {
  const _Dashboard({required this.dashboard});

  final StoresState dashboard;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = dashboard.groups;
    // How long the overview takes to fade from one state to the next; nothing
    // under reduced motion.
    final swap = Motion.of(context).base;
    if (groups.isEmpty) {
      final Widget body;
      if (dashboard.refreshing) {
        body = const _Skeletons(key: ValueKey('skeletons'));
      } else {
        body = PanePlaceholder(
          key: const ValueKey('empty'),
          icon: AppIcons.package,
          message: dashboard.stores.isEmpty
              ? 'Nothing has been read from the stores yet. Refresh to read '
                    'them.'
              : 'The stores list no apps for these credentials.',
        );
      }
      return AnimatedSwitcher(duration: swap, child: body);
    }
    final selection = ref.watch(storesSelectionProvider);
    StoreAppGroup? selected;
    for (final group in groups) {
      if (group.has(selection)) selected = group;
    }
    void select(String? appKey) =>
        ref.read(storesSelectionProvider.notifier).select(appKey);

    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final expanded = WidthClass.of(width, textScaler: scaler).isExpanded;
        final gutter = expanded ? Insets.xl : Insets.lg;
        final open = selected;
        if (open == null) {
          return SingleChildScrollView(
            key: const PageStorageKey('stores-overview'),
            padding: EdgeInsets.fromLTRB(gutter, Insets.md, gutter, Insets.xl),
            child: Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: kStoresContentMaxWidth,
                ),
                child: _Overview(
                  groups: groups,
                  refreshedAt: dashboard.refreshedAt,
                  selected: null,
                  // One column below expanded, whatever would fit (§6).
                  singleColumn: !expanded,
                  onSelect: select,
                ),
              ),
            ),
          );
        }
        if (!expanded) {
          return PopScope(
            // Back leaves the detail before it leaves the page.
            canPop: false,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) select(null);
            },
            child: StoreGroupDetail(
              group: open,
              pushed: true,
              onClose: () => select(null),
            ),
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: WidthClass.scaleBreakpoint(kStoresListWidth, scaler),
              child: SingleChildScrollView(
                key: const PageStorageKey('stores-list'),
                padding: const EdgeInsets.fromLTRB(
                  Insets.lg,
                  Insets.md,
                  Insets.lg,
                  Insets.xl,
                ),
                child: _Overview(
                  groups: groups,
                  refreshedAt: dashboard.refreshedAt,
                  selected: open.key,
                  singleColumn: true,
                  onSelect: select,
                ),
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: StoreGroupDetail(
                key: ValueKey(open.key),
                group: open,
                pushed: false,
                onClose: () => select(null),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The counts that matter as filters, then the apps — sectioned by what
/// they need when every app is shown.
class _Overview extends ConsumerWidget {
  const _Overview({
    required this.groups,
    required this.refreshedAt,
    required this.selected,
    required this.singleColumn,
    required this.onSelect,
  });

  final List<StoreAppGroup> groups;
  final DateTime? refreshedAt;
  final String? selected;
  final bool singleColumn;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(storesFilterProvider);
    bool inFilter(StoresFilter filter, StoreAppGroup group) => switch (filter) {
      StoresFilter.all => true,
      StoresFilter.attention => group.needsAttention,
      StoresFilter.inProgress => !group.needsAttention && group.inFlight,
      StoresFilter.newReviews => group.newReviewCount > 0,
    };
    final counts = {
      for (final f in StoresFilter.values)
        f: groups.where((group) => inFilter(f, group)).length,
    };
    final sections = <(String?, List<StoreAppGroup>)>[];
    if (filter == StoresFilter.all) {
      final attention = groups.where((g) => g.needsAttention).toList();
      final moving = groups
          .where((g) => !g.needsAttention && g.inFlight)
          .toList();
      final rest = groups
          .where((g) => !g.needsAttention && !g.inFlight)
          .toList();
      final sectioned = attention.isNotEmpty || moving.isNotEmpty;
      if (attention.isNotEmpty) sections.add(('Needs attention', attention));
      if (moving.isNotEmpty) sections.add(('In progress', moving));
      if (rest.isNotEmpty) {
        sections.add((sectioned ? 'Everything else' : null, rest));
      }
    } else {
      sections.add((
        null,
        [
          for (final g in groups)
            if (inFilter(filter, g)) g,
        ],
      ));
    }
    final shown = sections.fold(0, (sum, section) => sum + section.$2.length);
    // How long the overview takes to fade from one state to the next; nothing
    // under reduced motion.
    final swap = Motion.of(context).base;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SummaryStrip(
          counts: counts,
          filter: filter,
          compact: singleColumn,
          onPick: ref.read(storesFilterProvider.notifier).toggle,
        ),
        const SizedBox(height: Insets.lg),
        AnimatedSwitcher(
          duration: swap,
          child: KeyedSubtree(
            key: ValueKey(filter),
            child: shown == 0
                ? _NothingToShow(filter: filter)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (i, (title, members)) in sections.indexed) ...[
                        if (title != null)
                          Padding(
                            padding: EdgeInsets.only(
                              top: i == 0 ? 0 : Insets.md,
                              bottom: Insets.sm,
                            ),
                            child: Semantics(
                              header: true,
                              child: EyebrowLabel('$title · ${members.length}'),
                            ),
                          ),
                        _CardGrid(
                          groups: members,
                          refreshedAt: refreshedAt,
                          selected: selected,
                          singleColumn: singleColumn,
                          onSelect: onSelect,
                        ),
                      ],
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

/// The cards in as many columns as fit, each row as wide as the grid.
class _CardGrid extends StatelessWidget {
  const _CardGrid({
    required this.groups,
    required this.refreshedAt,
    required this.selected,
    required this.singleColumn,
    required this.onSelect,
  }) : skeletons = 0;

  const _CardGrid.skeletons()
    : groups = const [],
      refreshedAt = null,
      selected = null,
      singleColumn = false,
      onSelect = null,
      skeletons = 6;

  final List<StoreAppGroup> groups;
  final DateTime? refreshedAt;
  final String? selected;
  final bool singleColumn;
  final ValueChanged<String?>? onSelect;
  final int skeletons;

  static const maxColumns = 3;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final count = skeletons > 0 ? skeletons : groups.length;
    Widget cell(int i) {
      if (skeletons > 0) return const StoreCardSkeleton();
      final group = groups[i];
      return StoreGroupCard(
        group: group,
        refreshedAt: refreshedAt,
        selected: group.key == selected,
        onTap: () => onSelect?.call(group.key),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final card = WidthClass.scaleBreakpoint(kStoreCardMinWidth, scaler);
        final fit = ((constraints.maxWidth + Insets.md) / (card + Insets.md))
            .floor();
        final columns = singleColumn ? 1 : fit.clamp(1, maxColumns);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var start = 0; start < count; start += columns)
              Padding(
                padding: const EdgeInsets.only(bottom: Insets.md),
                child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = start; i < start + columns; i++) ...[
                        if (i > start) const SizedBox(width: Insets.md),
                        Expanded(
                          child: i < count ? cell(i) : const SizedBox.shrink(),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
