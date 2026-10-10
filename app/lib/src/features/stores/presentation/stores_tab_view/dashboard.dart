// The dashboard, its one list of apps and the card grid.

part of '../stores_tab_view.dart';

/// The overview and the selected app's detail: beside it at expanded width,
/// in its place below it.
class _Dashboard extends ConsumerWidget {
  const _Dashboard({required this.dashboard, required this.layout});

  final StoresState dashboard;
  final StoresLayout layout;

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
                  layout: layout,
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
                  layout: layout,
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

/// The filters, then every app once, in its section: as table rows, a row
/// per store it is on, or as cards, one per app.
class _Overview extends ConsumerWidget {
  const _Overview({
    required this.groups,
    required this.layout,
    required this.refreshedAt,
    required this.selected,
    required this.singleColumn,
    required this.onSelect,
  });

  final List<StoreAppGroup> groups;
  final StoresLayout layout;
  final DateTime? refreshedAt;
  final String? selected;
  final bool singleColumn;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(storesFilterProvider);
    final counts = {
      for (final f in StoresFilter.values)
        f: groups.where((group) => f.shows(group)).length,
    };
    final sections = storeSections(groups.where(filter.shows));
    // A heading only says something beside another.
    final titled = sections.length > 1;
    // How long the list takes to fade from one state to the next; nothing
    // under reduced motion.
    final swap = Motion.of(context).base;
    final Widget list;
    if (sections.isEmpty) {
      list = _NothingToShow(filter: filter);
    } else if (layout == StoresLayout.table) {
      list = StoreSummaryTable(
        sections: [
          for (final (section, members) in sections)
            (
              title: titled ? section.title : null,
              apps: members.length,
              rows: [for (final group in members) ...storeSummaryRowsOf(group)],
            ),
        ],
        selected: selected,
        onOpen: onSelect,
      );
    } else {
      list = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, (section, members)) in sections.indexed) ...[
            if (titled)
              Padding(
                padding: EdgeInsets.only(
                  top: i == 0 ? 0 : Insets.md,
                  bottom: Insets.sm,
                ),
                child: Semantics(
                  header: true,
                  child: EyebrowLabel(
                    '${section.title} · ${members.length}',
                    key: ValueKey('stores-section:${section.name}'),
                  ),
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
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _FilterRow(
          counts: counts,
          filter: filter,
          onPick: ref.read(storesFilterProvider.notifier).toggle,
        ),
        const SizedBox(height: Insets.md),
        AnimatedSwitcher(
          duration: swap,
          child: KeyedSubtree(key: ValueKey((filter, layout)), child: list),
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
