// The filter chips at the top of the list.

part of '../stores_tab_view.dart';

/// The counts as filters — needs attention, in progress, new reviews, all —
/// as compact count chips, a thumb's target under touch. A count of nothing
/// is left out, unless it is the filter on; All always shows.
class _FilterRow extends StatelessWidget {
  const _FilterRow({
    required this.counts,
    required this.filter,
    required this.onPick,
  });

  final Map<StoresFilter, int> counts;
  final StoresFilter filter;
  final ValueChanged<StoresFilter> onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final density = UiDensity.of(context);
    return Wrap(
      key: const ValueKey('stores-filters'),
      spacing: Insets.xs,
      runSpacing: Insets.xs,
      children: [
        for (final f in StoresFilter.values)
          if (f == StoresFilter.all || f == filter || (counts[f] ?? 0) > 0)
            FilterChip(
              key: ValueKey('stores-filter:${f.name}'),
              label: Text('${f.label} ${counts[f] ?? 0}'),
              labelStyle: theme.textTheme.labelSmall,
              selected: filter == f,
              showCheckmark: false,
              visualDensity: density.controlDensity,
              materialTapTargetSize: density.tapTargetSize,
              labelPadding: const EdgeInsets.symmetric(horizontal: Insets.xs),
              padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
              onSelected: (_) => onPick(f),
            ),
      ],
    );
  }
}
