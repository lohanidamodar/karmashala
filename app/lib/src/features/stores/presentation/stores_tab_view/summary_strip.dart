// The summary strip and its tiles.

part of '../stores_tab_view.dart';

/// The four counts — needs attention, in progress, new reviews, all — as
/// filters: tiles with the figure large where there is room, chips where not.
class _SummaryStrip extends StatelessWidget {
  const _SummaryStrip({
    required this.counts,
    required this.filter,
    required this.compact,
    required this.onPick,
  });

  final Map<StoresFilter, int> counts;
  final StoresFilter filter;
  final bool compact;
  final ValueChanged<StoresFilter> onPick;

  static const _order = [
    StoresFilter.attention,
    StoresFilter.inProgress,
    StoresFilter.newReviews,
    StoresFilter.all,
  ];

  Color _ink(BuildContext context, StoresFilter f, int count) {
    final semantic = SemanticColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (count == 0 || f == StoresFilter.all) return scheme.onSurface;
    return switch (f) {
      StoresFilter.attention => semantic.failure,
      StoresFilter.inProgress => semantic.working,
      StoresFilter.newReviews => semantic.unread,
      StoresFilter.all => scheme.onSurface,
    };
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final scaler = MediaQuery.textScalerOf(context);
        final roomy =
            !compact &&
            constraints.maxWidth >= WidthClass.scaleBreakpoint(560, scaler);
        if (!roomy) {
          return Wrap(
            spacing: Insets.xs,
            runSpacing: Insets.xs,
            children: [
              for (final f in _order)
                ChoiceChip(
                  label: Text('${f.label} ${counts[f] ?? 0}'),
                  selected: filter == f,
                  onSelected: f != StoresFilter.all && (counts[f] ?? 0) == 0
                      ? null
                      : (_) => onPick(f),
                ),
            ],
          );
        }
        return Row(
          children: [
            for (final (i, f) in _order.indexed) ...[
              if (i > 0) const SizedBox(width: Insets.md),
              Expanded(
                child: _SummaryTile(
                  label: f.label,
                  count: counts[f] ?? 0,
                  ink: _ink(context, f, counts[f] ?? 0),
                  selected: filter == f,
                  onTap: f != StoresFilter.all && (counts[f] ?? 0) == 0
                      ? null
                      : () => onPick(f),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _SummaryTile extends StatelessWidget {
  const _SummaryTile({
    required this.label,
    required this.count,
    required this.ink,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final Color ink;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      button: onTap != null,
      selected: selected,
      label: '$label: $count',
      child: ExcludeSemantics(
        child: Material(
          color: selected
              ? SurfaceTones.of(context).selected
              : scheme.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.md),
            side: BorderSide(
              color: selected ? scheme.primary : scheme.outlineVariant,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Insets.md,
                vertical: Insets.sm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$count',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      color: ink,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
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
