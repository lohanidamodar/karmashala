import 'package:flutter/material.dart';
import 'package:karmashala_ui/charts.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:store_console/store_console.dart';

import '../application/store_summary.dart';
import 'store_app_icon.dart';
import 'store_badges.dart';
import 'store_installs.dart';
import 'store_logo.dart';
import 'stores_format.dart';

/// How wide the summary's rating sparkline is drawn.
const double kSummarySparklineWidth = 56;

/// How tall it is.
const double kSummarySparklineHeight = 16;

/// What a reading the store does not give says, never a zero.
const String kNotReported = 'not reported';

/// What an active-devices figure counts, for its tooltip.
const String kActiveDevicesMeaning =
    'Devices with the app installed that were online in the last 30 days, '
    'from Google Play\'s installs reports. Devices, not people.';

/// One section of the summary: its heading — none when it is the only one —
/// and its rows, one per app.
typedef StoreSummarySection = ({
  String? title,
  int apps,
  List<StoreSummaryApp> rows,
});

/// **The summary across every app**: a row per app — its icon and the
/// stores it is on, then a line per store in each cell for what is live, the
/// rating with a month's trend, new and unanswered reviews and the crash and
/// ANR rate; the installs added up where that is honest, with the last 30
/// days under them; Google Play's active devices; and whether it changed
/// since last seen — in the list's sections, a heading row between them. A
/// table where it is wide, a list of compact rows where not. Tapping a row
/// opens its app.
class StoreSummaryTable extends StatelessWidget {
  const StoreSummaryTable({
    required this.sections,
    required this.onOpen,
    this.selected,
    super.key,
  });

  final List<StoreSummarySection> sections;

  /// Called with the tapped row's group key.
  final ValueChanged<String> onOpen;

  /// The group key whose detail is open.
  final String? selected;

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
        final children = <Widget>[if (wide) const _HeaderRow()];
        for (final section in sections) {
          if (section.title case final title?) {
            if (children.isNotEmpty) children.add(const Divider(height: 1));
            children.add(_SectionRow(title: title, apps: section.apps));
          }
          for (final app in section.rows) {
            if (children.isNotEmpty) children.add(const Divider(height: 1));
            children.add(
              _SummaryRow(
                key: ValueKey('store-summary-row:${app.key}'),
                app: app,
                wide: wide,
                selected: app.key == selected,
                onTap: () => onOpen(app.key),
              ),
            );
          }
        }
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
              children: children,
            ),
          ),
        );
      },
    );
  }
}

/// A section's heading inside the table.
class _SectionRow extends StatelessWidget {
  const _SectionRow({required this.title, required this.apps});

  final String title;
  final int apps;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.md,
          vertical: Insets.xs,
        ),
        child: Semantics(header: true, child: EyebrowLabel('$title · $apps')),
      ),
    );
  }
}

/// The table's columns and their shares of the width.
enum _Column {
  app('App', 4),
  live('Live', 3),
  rating('Rating · 30 days', 3),
  installs('Installs', 3),
  devices('Active devices', 2),
  reviews('New reviews', 3),
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
                child: Padding(
                  padding: const EdgeInsets.only(right: Insets.sm),
                  child: Text(
                    column.title,
                    style: style,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            const SizedBox(width: Chrome.iconAction),
          ],
        ),
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.app,
    required this.wide,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final StoreSummaryApp app;
  final bool wide;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: _spoken(app),
      child: ExcludeSemantics(
        child: InkWell(
          onTap: onTap,
          child: Ink(
            color: selected ? SurfaceTones.of(context).selected : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Insets.md,
                vertical: Insets.sm,
              ),
              child: wide ? _WideCells(app: app) : _CompactCells(app: app),
            ),
          ),
        ),
      ),
    );
  }

  static String _spoken(StoreSummaryApp app) {
    final installs = app.installs;
    final figure = summaryInstallsFigure(installs);
    final recent = app.recentInstalls;
    final devices = app.activeDevices;
    return [
      app.name,
      if (app.group.combinedManually) 'combined manually',
      for (final row in app.stores) _spokenStore(row),
      if (figure != null)
        '$figure installs, ${summaryInstallsPeriod(installs, app)}'
      else
        'installs $kNotReported',
      if (recent != null) '$recent in the last 30 days',
      if (devices != null) '$devices active devices',
      if (app.changedUnseen) 'changed since last seen',
    ].join(', ');
  }

  static String _spokenStore(StoreSummaryRow row) {
    final live = row.live;
    final rating = row.rating;
    return [
      '${row.app.store.label}, ${row.platform}',
      if (live != null)
        'live ${formatVersion(live)} ${formatReleaseState(live)}'
      else
        'nothing live',
      if (rating != null)
        'rated ${rating.average.toStringAsFixed(1)}'
      else
        'rating $kNotReported',
      _reviewsText(row),
      _stabilityText(row.vitals, long: true),
    ].join(', ');
  }
}

/// The figure the row shows for its installs: the exact counts added up,
/// else the listing's band; null when no store gave either.
String? summaryInstallsFigure(SummaryInstalls installs) {
  if (installs.count case final count?) return formatCompactCount(count);
  if (installs.band case (_, final band)) return formatInstallFigure(band);
  return null;
}

/// What period [installs] covers, under the figure: `all time` only when
/// every store counted gave its own lifetime figure, else where each sum
/// starts — `since Mar 2019`, `App Store since Jan 2025 · Play since Mar
/// 2019` — and which store alone is counted when the other is not.
String summaryInstallsPeriod(SummaryInstalls installs, StoreSummaryApp app) {
  String from(InstallTotal total) => switch (total.since) {
    null => 'all time',
    final since => 'since ${formatInstallPeriod(since)}',
  };
  if (installs.band case (final store, _)) {
    return '${storeShortLabel(store)} listing band';
  }
  final counted = installs.counted;
  if (counted.isEmpty) return kNotReported;
  if (counted.length == 1) {
    final (store, total) = counted.single;
    return app.onBoth
        ? '${storeShortLabel(store)} only, ${from(total)}'
        : from(total);
  }
  if (installs.lifetime) return 'all time';
  return [
    for (final (store, total) in counted)
      '${storeShortLabel(store)} ${from(total)}',
  ].join(' · ');
}

/// Each store's count in full, for the installs tooltip.
String _installsDetail(StoreSummaryApp app) {
  final installs = app.installs;
  return [
    for (final (store, total) in installs.counted)
      describeInstallTotal(total, store),
    if (installs.band case (final store, final band))
      describeInstallTotal(band, store),
    for (final store in installs.missing) '${store.label}: $kNotReported.',
    if (app.recentInstalls != null)
      [
        for (final row in app.stores)
          if (row.recentInstalls case final recent?)
            '${row.app.store.label}: ${recent.count} over the last 30 days '
                '(${recent.days} days reported).',
      ].join('\n'),
  ].join('\n');
}

String _reviewsText(StoreSummaryRow row) {
  final count = row.newReviewCount;
  if (count == null) return 'reviews $kNotReported';
  final unanswered = row.unanswered ?? 0;
  if (count == 0) return 'no new reviews';
  return unanswered == 0 ? '$count new' : '$count new · $unanswered unanswered';
}

String _stabilityText(
  VitalsSummary? vitals, {
  bool long = false,
  bool labelled = false,
}) {
  final crash = vitals?.crashRate;
  final anr = vitals?.anrRate;
  if (crash == null && anr == null) {
    if (long) return 'crash and ANR rate $kNotReported';
    return labelled ? 'Crashes · ANRs $kNotReported' : kNotReported;
  }
  String rate(double? value) =>
      value == null ? kNotReported : formatRate(value);
  return 'Crashes ${rate(crash)} · ANRs ${rate(anr)}';
}

class _Name extends StatelessWidget {
  const _Name({required this.app});

  final StoreSummaryApp app;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Row(
      children: [
        StoreAppIconView(
          icon: app.group.icon,
          name: app.name,
          size: Chrome.iconTitle + Insets.sm,
        ),
        const SizedBox(width: Insets.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                app.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              Row(
                children: [
                  for (final row in app.stores) ...[
                    StoreLogo(row.app.store, size: Chrome.iconAction),
                    const SizedBox(width: Insets.xxs),
                  ],
                  if (app.group.combinedManually) ...[
                    Tooltip(
                      message: 'Combined manually',
                      child: Icon(
                        AppIcons.linkSimple,
                        key: const ValueKey('store-summary-combined'),
                        size: Chrome.iconAction,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: Insets.xxs),
                  ],
                  Flexible(
                    child: Text(
                      app.stores.map((row) => row.platform).join(' · '),
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

/// A cell holding a line per store: each behind its store's logo when the
/// app is on both, the one store's alone when not.
class _PerStore extends StatelessWidget {
  const _PerStore({required this.app, required this.cell});

  final StoreSummaryApp app;
  final Widget Function(StoreSummaryRow row) cell;

  @override
  Widget build(BuildContext context) {
    if (!app.onBoth) return cell(app.stores.single);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, row) in app.stores.indexed) ...[
          if (i > 0) const SizedBox(height: Insets.xxs),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: Insets.hair),
                child: StoreLogo(row.app.store, size: Chrome.iconAction),
              ),
              const SizedBox(width: Insets.xs),
              Expanded(child: cell(row)),
            ],
          ),
        ],
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
    return Wrap(
      spacing: Insets.sm,
      runSpacing: Insets.xxs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        RatingFigure(rating: rating),
        if (trend.length > 1)
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
    );
  }
}

/// The installs cell: the figure, the period it covers, and the last 30
/// days; on hover each store's count in full.
class _Installs extends StatelessWidget {
  const _Installs({required this.app});

  final StoreSummaryApp app;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final installs = app.installs;
    final figure = summaryInstallsFigure(installs);
    final recent = app.recentInstalls;
    if (figure == null && recent == null) return const _Muted(kNotReported);
    return Tooltip(
      message: _installsDetail(app),
      child: Column(
        key: ValueKey('store-summary-installs:${app.key}'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            figure ?? kNotReported,
            style: figure == null
                ? theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  )
                : theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
          ),
          if (figure != null) _Muted(summaryInstallsPeriod(installs, app)),
          if (recent != null) _Muted(_recentText(recent)),
        ],
      ),
    );
  }
}

String _recentText(int recent) => '+${formatCompactCount(recent)} in 30 days';

/// Google Play's active devices, with what they count on hover.
class _Devices extends StatelessWidget {
  const _Devices({required this.app, this.labelled = false});

  final StoreSummaryApp app;

  /// Whether the figure says `devices` after it, where there is no header.
  final bool labelled;

  @override
  Widget build(BuildContext context) {
    final devices = app.activeDevices;
    if (devices == null) {
      return labelled ? const SizedBox.shrink() : const _Muted(kNotReported);
    }
    final figure = formatCompactCount(devices);
    final day = app.stores
        .map((row) => row.allTime?.activeDevicesDay)
        .whereType<DateTime>()
        .firstOrNull;
    final figureText = Text(
      labelled ? '$figure active devices' : figure,
      key: ValueKey('store-summary-devices:${app.key}'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: labelled ? Theme.of(context).colorScheme.onSurfaceVariant : null,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
    return Tooltip(
      message: [
        kActiveDevicesMeaning,
        if (day != null) 'Counted on ${formatReportDay(day)}.',
      ].join('\n'),
      child: app.onBoth && !labelled
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const StoreLogo(StoreKind.googlePlay, size: Chrome.iconAction),
                const SizedBox(width: Insets.xs),
                Flexible(child: figureText),
              ],
            )
          : figureText,
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

class _Reviews extends StatelessWidget {
  const _Reviews({required this.row});

  final StoreSummaryRow row;

  @override
  Widget build(BuildContext context) => _Muted(
    _reviewsText(row),
    color: (row.unanswered ?? 0) > 0 ? SemanticColors.of(context).unread : null,
  );
}

/// The bell that says the app changed since somebody last opened it.
class _Changed extends StatelessWidget {
  const _Changed({required this.app});

  final StoreSummaryApp app;

  @override
  Widget build(BuildContext context) {
    if (!app.changedUnseen) {
      return const SizedBox(width: Chrome.iconAction);
    }
    final unseen = [
      for (final held in app.group.changes)
        if (!held.seen) held,
    ];
    final attention = unseen.any((held) => held.attention);
    final semantic = SemanticColors.of(context);
    return Tooltip(
      message: unseen.map((held) => held.sentence).join('\n'),
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
  const _WideCells({required this.app});

  final StoreSummaryApp app;

  @override
  Widget build(BuildContext context) {
    Widget cell(_Column column, Widget child) => Expanded(
      flex: column.flex,
      child: Padding(
        padding: const EdgeInsets.only(right: Insets.sm),
        child: child,
      ),
    );
    return Row(
      children: [
        cell(_Column.app, _Name(app: app)),
        cell(
          _Column.live,
          _PerStore(
            app: app,
            cell: (row) => _Live(row: row),
          ),
        ),
        cell(
          _Column.rating,
          _PerStore(
            app: app,
            cell: (row) => _Rating(row: row),
          ),
        ),
        cell(_Column.installs, _Installs(app: app)),
        cell(_Column.devices, _Devices(app: app)),
        cell(
          _Column.reviews,
          _PerStore(
            app: app,
            cell: (row) => _Reviews(row: row),
          ),
        ),
        cell(
          _Column.stability,
          _PerStore(
            app: app,
            cell: (row) => _Muted(_stabilityText(row.vitals)),
          ),
        ),
        _Changed(app: app),
      ],
    );
  }
}

class _CompactCells extends StatelessWidget {
  const _CompactCells({required this.app});

  final StoreSummaryApp app;

  @override
  Widget build(BuildContext context) {
    final installs = app.installs;
    final figure = summaryInstallsFigure(installs);
    final recent = app.recentInstalls;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: _Name(app: app)),
            const SizedBox(width: Insets.sm),
            _Changed(app: app),
          ],
        ),
        const SizedBox(height: Insets.xs),
        Tooltip(
          message: _installsDetail(app),
          child: Wrap(
            key: ValueKey('store-summary-installs:${app.key}'),
            spacing: Insets.md,
            runSpacing: Insets.xxs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _Muted(
                figure == null
                    ? 'Installs $kNotReported'
                    : '$figure installs, '
                          '${summaryInstallsPeriod(installs, app)}',
              ),
              if (recent != null) _Muted(_recentText(recent)),
            ],
          ),
        ),
        if (app.activeDevices != null) _Devices(app: app, labelled: true),
        for (final row in app.stores) ...[
          const SizedBox(height: Insets.xs),
          _StoreLine(row: row, logo: app.onBoth),
        ],
      ],
    );
  }
}

/// One store's facts on a narrow row, behind its logo when the app is on
/// both stores.
class _StoreLine extends StatelessWidget {
  const _StoreLine({required this.row, required this.logo});

  final StoreSummaryRow row;
  final bool logo;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: Insets.md,
      runSpacing: Insets.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (logo) StoreLogo(row.app.store, size: Chrome.iconAction),
        _Live(row: row),
        _Rating(row: row),
        _Reviews(row: row),
        _Muted(_stabilityText(row.vitals, labelled: true)),
      ],
    );
  }
}

/// What the table says of a listing that a card's store line does not: the
/// month's rating trend, new and unanswered reviews, and the crash and ANR
/// rate — so switching to the cards loses nothing.
class StoreListingFacts extends StatelessWidget {
  const StoreListingFacts({required this.row, super.key});

  final StoreSummaryRow row;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final trend = row.ratingTrend;
    return Wrap(
      key: ValueKey('store-listing-facts:${row.app.key}'),
      spacing: Insets.md,
      runSpacing: Insets.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (trend.length > 1)
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
        _Reviews(row: row),
        _Muted(_stabilityText(row.vitals, labelled: true)),
      ],
    );
  }
}
