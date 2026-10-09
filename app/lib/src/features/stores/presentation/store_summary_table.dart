import 'package:flutter/material.dart';
import 'package:karmashala_ui/charts.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:store_console/store_console.dart';

import '../application/store_summary.dart';
import 'store_app_icon.dart';
import 'store_badges.dart';
import 'store_logo.dart';
import 'stores_format.dart';

/// How wide the summary's rating sparkline is drawn.
const double kSummarySparklineWidth = 56;

/// How tall it is.
const double kSummarySparklineHeight = 16;

/// What a reading the store does not give says, never a zero.
const String kNotReported = 'not reported';

/// **The summary across every app**: a row per app per store — its icon and
/// platform, what is live, the rating with a month's trend, new and
/// unanswered reviews, the crash and ANR rate, and whether it changed since
/// last seen — what needs attention first. A table where it is wide, a list
/// of compact rows on a phone. Tapping a row opens its app.
class StoreSummaryTable extends StatelessWidget {
  const StoreSummaryTable({
    required this.rows,
    required this.onOpen,
    super.key,
  });

  /// In [storeSummaryRows]' order.
  final List<StoreSummaryRow> rows;

  /// Called with the tapped row's group key.
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = WidthClass.of(
          constraints.maxWidth,
          textScaler: scaler,
        ).isExpanded;
        return DecoratedBox(
          key: const ValueKey('store-summary'),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(Radii.md),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(Radii.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (wide) const _HeaderRow(),
                for (final (i, row) in rows.indexed) ...[
                  if (i > 0 || wide) const Divider(height: 1),
                  _SummaryRow(
                    key: ValueKey('store-summary-row:${row.app.key}'),
                    row: row,
                    wide: wide,
                    onTap: () => onOpen(row.group.key),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The table's columns and their shares of the width.
enum _Column {
  app('App', 4),
  live('Live', 3),
  rating('Rating · 30 days', 3),
  reviews('New reviews', 2),
  stability('Crashes · ANRs', 3);

  const _Column(this.title, this.flex);
  final String title;
  final int flex;
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return ExcludeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.md,
          vertical: Insets.sm,
        ),
        child: Row(
          children: [
            for (final column in _Column.values)
              Expanded(
                flex: column.flex,
                child: Text(
                  column.title,
                  style: style,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            const SizedBox(width: Chrome.iconAction + Insets.sm),
          ],
        ),
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.row,
    required this.wide,
    required this.onTap,
    super.key,
  });

  final StoreSummaryRow row;
  final bool wide;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: _spoken(row),
      child: ExcludeSemantics(
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.md,
              vertical: Insets.sm,
            ),
            child: wide ? _WideCells(row: row) : _CompactCells(row: row),
          ),
        ),
      ),
    );
  }

  static String _spoken(StoreSummaryRow row) {
    final live = row.live;
    final rating = row.rating;
    final vitals = row.vitals;
    return [
      '${row.app.name}, ${row.platform}, ${row.app.store.label}',
      if (live != null)
        'live ${formatVersion(live)} ${formatReleaseState(live)}'
      else
        'nothing live',
      if (rating != null)
        'rated ${rating.average.toStringAsFixed(1)}'
      else
        'rating $kNotReported',
      _reviewsText(row),
      _stabilityText(vitals, long: true),
      if (row.changedUnseen) 'changed since last seen',
    ].join(', ');
  }
}

String _reviewsText(StoreSummaryRow row) {
  final count = row.newReviewCount;
  if (count == null) return 'reviews $kNotReported';
  final unanswered = row.unanswered ?? 0;
  if (count == 0) return 'no new reviews';
  return unanswered == 0 ? '$count new' : '$count new · $unanswered unanswered';
}

String _stabilityText(VitalsSummary? vitals, {bool long = false}) {
  final crash = vitals?.crashRate;
  final anr = vitals?.anrRate;
  if (crash == null && anr == null) {
    return long ? 'crash and ANR rate $kNotReported' : kNotReported;
  }
  String rate(double? value) =>
      value == null ? kNotReported : formatRate(value);
  return 'Crashes ${rate(crash)} · ANRs ${rate(anr)}';
}

class _Name extends StatelessWidget {
  const _Name({required this.row});

  final StoreSummaryRow row;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Row(
      children: [
        StoreAppIconView(
          icon: row.entry.icon ?? row.group.icon,
          name: row.app.name,
          size: Chrome.iconTitle + Insets.sm,
        ),
        const SizedBox(width: Insets.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                row.app.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              Row(
                children: [
                  StoreLogo(row.app.store, size: Chrome.iconAction),
                  const SizedBox(width: Insets.xxs),
                  Flexible(
                    child: Text(
                      row.platform,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: muted,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Live extends StatelessWidget {
  const _Live({required this.row});

  final StoreSummaryRow row;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final live = row.live;
    final pending = row.pending;
    if (live == null && pending == null) {
      return Text(
        row.snapshot == null ? kNotReported : 'Nothing live',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    final shown = pending != null && pending.state.needsAttention
        ? pending
        : live ?? pending!;
    return Wrap(
      spacing: Insets.xs,
      runSpacing: Insets.xxs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          formatVersion(shown),
          style: theme.textTheme.bodySmall?.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        ReleaseStatePill(release: shown),
      ],
    );
  }
}

class _Rating extends StatelessWidget {
  const _Rating({required this.row});

  final StoreSummaryRow row;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rating = row.rating;
    if (rating == null) {
      return Text(
        kNotReported,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    final trend = row.ratingTrend;
    return Row(
      children: [
        RatingFigure(rating: rating),
        if (trend.length > 1) ...[
          const SizedBox(width: Insets.sm),
          Sparkline(
            values: trend,
            color: theme.colorScheme.primary,
            minValue: ratingTrendScale(trend).min,
            maxValue: ratingTrendScale(trend).max,
            width: kSummarySparklineWidth,
            height: kSummarySparklineHeight,
            area: false,
            semanticsLabel: 'Rating over the last 30 days',
          ),
        ],
      ],
    );
  }
}

class _Muted extends StatelessWidget {
  const _Muted(this.text, {this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodySmall?.copyWith(
        color: color ?? theme.colorScheme.onSurfaceVariant,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

/// The dot that says the app changed since somebody last opened it.
class _Changed extends StatelessWidget {
  const _Changed({required this.row});

  final StoreSummaryRow row;

  @override
  Widget build(BuildContext context) {
    if (!row.changedUnseen) {
      return const SizedBox(width: Chrome.iconAction);
    }
    final attention = row.entry.changes?.attention ?? false;
    final semantic = SemanticColors.of(context);
    return Tooltip(
      message: row.entry.changes?.sentence ?? 'Changed',
      child: Icon(
        AppIcons.bellSimple,
        key: const ValueKey('store-summary-changed'),
        size: Chrome.iconAction,
        color: attention
            ? semantic.attention
            : Theme.of(context).colorScheme.primary,
      ),
    );
  }
}

class _WideCells extends StatelessWidget {
  const _WideCells({required this.row});

  final StoreSummaryRow row;

  @override
  Widget build(BuildContext context) {
    final unanswered = row.unanswered ?? 0;
    return Row(
      children: [
        Expanded(
          flex: _Column.app.flex,
          child: _Name(row: row),
        ),
        Expanded(
          flex: _Column.live.flex,
          child: _Live(row: row),
        ),
        Expanded(
          flex: _Column.rating.flex,
          child: _Rating(row: row),
        ),
        Expanded(
          flex: _Column.reviews.flex,
          child: _Muted(
            _reviewsText(row),
            color: unanswered > 0 ? SemanticColors.of(context).unread : null,
          ),
        ),
        Expanded(
          flex: _Column.stability.flex,
          child: _Muted(_stabilityText(row.vitals)),
        ),
        const SizedBox(width: Insets.sm),
        _Changed(row: row),
      ],
    );
  }
}

class _CompactCells extends StatelessWidget {
  const _CompactCells({required this.row});

  final StoreSummaryRow row;

  @override
  Widget build(BuildContext context) {
    final unanswered = row.unanswered ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: _Name(row: row)),
            const SizedBox(width: Insets.sm),
            _Changed(row: row),
          ],
        ),
        const SizedBox(height: Insets.xs),
        Wrap(
          spacing: Insets.md,
          runSpacing: Insets.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _Live(row: row),
            _Rating(row: row),
            _Muted(
              _reviewsText(row),
              color: unanswered > 0 ? SemanticColors.of(context).unread : null,
            ),
            _Muted(_stabilityText(row.vitals)),
          ],
        ),
      ],
    );
  }
}
