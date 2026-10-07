import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/charts.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:store_console/store_console.dart';

import '../../../core/util/clock_provider.dart';
import '../../git/application/remote_links.dart' show openExternalUrlProvider;
import '../application/store_attention.dart';
import '../application/store_groups.dart';
import 'store_app_icon.dart';
import 'store_logo.dart';
import 'store_badges.dart';
import 'store_combine.dart';
import 'store_detail_errors.dart';
import 'store_detail_releases.dart';
import 'store_detail_reviews.dart';
import 'store_installs.dart';
import 'stores_format.dart';

/// The detail's own width, at 1x text, from which its body runs in two
/// columns.
const double kStoreDetailTwoColumnMin = 960;

/// The widest the two-column detail runs, so a 4K window does not stretch it.
const double kStoreDetailMaxWidth = 1280;

/// How the detail lays itself out, by the width it was given (PROJECT.md §6).
enum _Layout {
  /// A phone, or the detail beside the list in a small window: one column.
  narrow,

  /// One column with more tiles to a row.
  medium,

  /// Releases and numbers side by side; reviews beside their filters.
  wide;

  static _Layout of(double width, TextScaler scaler) {
    if (WidthClass.of(width, textScaler: scaler).isCompact) return narrow;
    final twoColumns = WidthClass.scaleBreakpoint(
      kStoreDetailTwoColumnMin,
      scaler,
    );
    return width >= twoColumns ? wide : medium;
  }

  int get tileColumns => this == narrow ? 2 : 4;
  double get gutter => this == wide ? Insets.xl : Insets.lg;
  double get maxWidth =>
      this == wide ? kStoreDetailMaxWidth : Chrome.readableWidth;
}

/// Everything read about one app: what wants a look, its releases per store
/// and track, its numbers, its downloads and its reviews.
class StoreGroupDetail extends StatelessWidget {
  const StoreGroupDetail({
    required this.group,
    required this.onClose,
    required this.pushed,
    super.key,
  });

  final StoreAppGroup group;
  final VoidCallback onClose;

  /// Whether this stands in the dashboard's place (compact) rather than
  /// beside it: the way out is then a back arrow, not a close.
  final bool pushed;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = _Layout.of(constraints.maxWidth, scaler);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(
              group: group,
              pushed: pushed,
              onClose: onClose,
              layout: layout,
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  layout.gutter,
                  Insets.md,
                  layout.gutter,
                  Insets.xxl,
                ),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: layout.maxWidth),
                    child: _Body(group: group, layout: layout),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.group, required this.layout});

  final StoreAppGroup group;
  final _Layout layout;

  @override
  Widget build(BuildContext context) {
    final read = group.entries.any((entry) => entry.snapshot != null);
    final wide = layout == _Layout.wide;
    final charts = read ? _downloadCharts(group, layout) : const <Widget>[];

    final wantsALook = group.signals.isEmpty
        ? null
        : _Section('Wants a look', child: _SignalsPanel(group: group));
    final numbers = read
        ? _Section(
            'Ratings and stability',
            child: _Numbers(group: group, maxColumns: layout.tileColumns),
          )
        : null;
    final downloads = charts.isEmpty
        ? null
        : _Section('Downloads', child: _Stack(children: charts));
    final crashes = read && hasErrorIssues(group)
        ? _Section(
            'Crashes and ANRs',
            child: StoreErrorIssuesSection(group: group),
          )
        : null;
    final numbersSide = [?numbers, ?downloads];

    final Widget status;
    if (wide && numbersSide.isNotEmpty) {
      // A column traversed whole before the next, not row by row.
      status = Row(
        key: const ValueKey('status'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: FocusTraversalGroup(
              child: _Sections(
                children: [
                  ?wantsALook,
                  _Section(
                    'Releases',
                    child: _Releases(group: group, sideBySide: false),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: Insets.xl),
          Expanded(
            child: FocusTraversalGroup(child: _Sections(children: numbersSide)),
          ),
        ],
      );
    } else {
      status = _Sections(
        key: const ValueKey('status'),
        children: [
          ?wantsALook,
          _Section(
            'Releases',
            child: _Releases(group: group, sideBySide: wide),
          ),
          ...numbersSide,
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Actions(group: group),
        status,
        ?crashes,
        // Keyed so its filters and paging survive a change of layout.
        _Section(
          'Reviews',
          key: const ValueKey('reviews'),
          child: StoreReviewsSection(group: group, sideBySide: wide),
        ),
      ],
    );
  }

  static List<Widget> _downloadCharts(StoreAppGroup group, _Layout layout) => [
    for (final entry in group.entries)
      if (entry.snapshot?.downloads.valueOrNull case final series?
          when series.days.length > 1)
        _DownloadsChart(
          store: group.entries.length > 1 ? entry.app.store : null,
          series: series,
          height: layout == _Layout.narrow ? 120 : 160,
        ),
  ];
}

/// Sections one under another: each brings its own space above it.
class _Sections extends StatelessWidget {
  const _Sections({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: children,
  );
}

/// [children] one under another, [Insets.md] apart.
class _Stack extends StatelessWidget {
  const _Stack({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final (i, child) in children.indexed) ...[
        if (i > 0) const SizedBox(height: Insets.md),
        child,
      ],
    ],
  );
}

/// A section: its heading, then [child]. Every section opens the same way,
/// so two columns' first headings line up.
class _Section extends StatelessWidget {
  const _Section(this.title, {required this.child, super.key});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: Insets.xl, bottom: Insets.sm),
        child: Semantics(header: true, child: EyebrowLabel(title)),
      ),
      child,
    ],
  );
}

/// A card in the detail's one style.
class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Padding(padding: const EdgeInsets.all(Insets.md), child: child),
    );
  }
}

/// The icon, the name, the ids, and each store the app is on with what is
/// live there.
class _Header extends StatelessWidget {
  const _Header({
    required this.group,
    required this.pushed,
    required this.onClose,
    required this.layout,
  });

  final StoreAppGroup group;
  final bool pushed;
  final VoidCallback onClose;
  final _Layout layout;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final narrow = layout == _Layout.narrow;
    final iconSize = StoreAppIconView.detailSize(context) - (narrow ? 8 : 0);
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        pushed ? Insets.xs : layout.gutter,
        Insets.md,
        Insets.xs,
        Insets.md,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (pushed) ...[
            IconButton(
              tooltip: 'Back to all apps',
              icon: const Icon(AppIcons.arrowLeft),
              onPressed: onClose,
            ),
            const SizedBox(width: Insets.xs),
          ],
          StoreAppIconView(icon: group.icon, name: group.name, size: iconSize),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    group.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style:
                        (narrow
                                ? theme.textTheme.titleMedium
                                : theme.textTheme.titleLarge)
                            ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(height: Insets.xxs),
                // Combined by hand, each store's id on its own line.
                for (final id in storeGroupIdLines(group))
                  SelectableText(
                    id,
                    // On a phone a long id wraps rather than scrolls.
                    maxLines: narrow ? null : 1,
                    style: MonoStyles.body.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                const SizedBox(height: Insets.sm),
                Wrap(
                  spacing: Insets.lg,
                  runSpacing: Insets.xs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final entry in group.entries)
                      _StorePresence(entry: entry),
                    if (group.combinedManually) const CombinedManuallyChip(),
                  ],
                ),
              ],
            ),
          ),
          if (!pushed) ...[
            const SizedBox(width: Insets.sm),
            IconButton(
              tooltip: 'Close details',
              icon: const Icon(AppIcons.x),
              onPressed: onClose,
            ),
          ],
        ],
      ),
    );
  }
}

/// One store in the header: its logo and name, and the version live there.
class _StorePresence extends StatelessWidget {
  const _StorePresence({required this.entry});

  final StoreEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final store = entry.app.store;
    final (status, isLive) = switch (entry.snapshot) {
      null => ('Not read yet', false),
      StoreAppSnapshot(releases: ReadingMissing()) => (
        'Releases unread',
        false,
      ),
      StoreAppSnapshot(:final live?) => (formatVersion(live), true),
      _ => ('Not live', false),
    };
    final style = theme.textTheme.bodySmall?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Semantics(
      container: true,
      label:
          '${store.label}: ${isLive ? 'live $status' : status.toLowerCase()}',
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: StoreLogo.named(
                store,
                size: Chrome.iconAction,
                color: scheme.onSurface,
                style: style?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: Insets.sm),
            if (isLive) ...[
              Container(
                width: Chrome.dot,
                height: Chrome.dot,
                decoration: BoxDecoration(
                  color: SemanticColors.of(context).idle,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: Insets.xs),
            ],
            Flexible(
              child: Text(
                status,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: isLive
                    ? style?.copyWith(fontWeight: FontWeight.w500)
                    : style?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Each store's console and listing, one click away, and combining.
class _Actions extends ConsumerWidget {
  const _Actions({required this.group});

  final StoreAppGroup group;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.read(openExternalUrlProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: Insets.sm,
          runSpacing: Insets.sm,
          children: [
            for (final entry in group.entries)
              for (final link in storeLinks(entry.app))
                OutlinedButton.icon(
                  onPressed: () => open(link.url),
                  icon: const Icon(
                    AppIcons.arrowSquareOut,
                    size: Chrome.iconAction,
                  ),
                  label: Text(
                    link.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
          ],
        ),
        if (group.combined != StoreCombined.byId) ...[
          const SizedBox(height: Insets.xs),
          StoreCombineBar(group: group),
        ],
      ],
    );
  }
}

/// One card per store: stacked, or side by side.
class _Releases extends StatelessWidget {
  const _Releases({required this.group, required this.sideBySide});

  final StoreAppGroup group;
  final bool sideBySide;

  @override
  Widget build(BuildContext context) {
    final cards = [
      for (final entry in group.entries)
        StoreReleasesCard(
          key: ValueKey('releases-${entry.app.key}'),
          entry: entry,
        ),
    ];
    if (!sideBySide || cards.length < 2) return _Stack(children: cards);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, card) in cards.indexed) ...[
          if (i > 0) const SizedBox(width: Insets.md),
          Expanded(child: card),
        ],
      ],
    );
  }
}

/// What wants a look, as sentences, loudest first.
class _SignalsPanel extends StatelessWidget {
  const _SignalsPanel({required this.group});

  final StoreAppGroup group;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final signals = group.signals;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, signal) in signals.indexed)
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : Insets.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: Insets.xxs),
                    child: Icon(
                      signalIcon(signal),
                      size: Chrome.icon,
                      color: signalColor(context, signal),
                    ),
                  ),
                  const SizedBox(width: Insets.sm),
                  Expanded(
                    child: Text(
                      signalSentence(signal),
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  if (signal case ReleaseSignal(
                    release: StoreRelease(rolloutFraction: final fraction?),
                  )) ...[
                    const SizedBox(width: Insets.sm),
                    Padding(
                      padding: const EdgeInsets.only(top: Insets.sm),
                      child: RolloutBar(fraction: fraction),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The headline numbers of every store; a reading the store did not give is
/// a line under them saying why, never a zero (PROJECT.md §19).
class _Numbers extends ConsumerWidget {
  const _Numbers({required this.group, required this.maxColumns});

  final StoreAppGroup group;
  final int maxColumns;

  static const _unavailable = 'unavailable';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider).nowUtc();
    final both = group.entries.length > 1;
    final tiles = <Widget>[];
    // Grouped under their store, so they read as one block per store.
    final notes = <StoreKind, List<Widget>>{};
    for (final entry in group.entries) {
      final snapshot = entry.snapshot;
      if (snapshot == null) continue;
      final store = entry.app.store;
      // Which store a tile is from, when there are two: its logo before the
      // label, its name for a screen reader (owner, 2026-10-01).
      final logo = both ? StoreLogo(store, size: Chrome.iconSmall) : null;
      String spoken(String what) => both ? '$what · ${store.label}' : what;
      void note(String what, ReadingMissing<Object?> missing) => notes
          .putIfAbsent(store, () => [])
          .add(MissingReadingLine(what: what, reading: missing));

      switch (snapshot.rating) {
        case ReadingValue(:final value):
          final trend = value.trend;
          final caption = [
            if (value.count case final count?)
              '${formatCompactCount(count)} ratings',
            if (trend != null)
              '${formatRatingChange(trend.change)} since '
                  '${formatShortDay(trend.since, now)}',
          ];
          tiles.add(
            StatTile(
              label: 'Rating',
              leading: logo,
              semanticLabel: spoken('Rating'),
              value: '${value.average.toStringAsFixed(1)} ★',
              caption: caption.isEmpty ? null : caption.join(' · '),
            ),
          );
        case final ReadingMissing<RatingSummary> missing:
          if (!missing.expected) {
            tiles.add(
              StatTile(
                label: 'Rating',
                leading: logo,
                semanticLabel: spoken('Rating'),
                value: null,
                unrecorded: _unavailable,
              ),
            );
          }
          note('Rating', missing);
      }

      switch (snapshot.vitals) {
        case ReadingValue(:final value):
          final window = '${value.to.difference(value.from).inDays} days';
          tiles
            ..add(
              StatTile(
                label: 'Crash rate',
                leading: logo,
                semanticLabel: spoken('Crash rate'),
                value: switch (value.crashRate) {
                  final rate? => formatRate(rate),
                  null => null,
                },
                unrecorded: 'too little data',
                caption: window,
                tooltip: 'The share of daily users who saw a crash.',
              ),
            )
            ..add(
              StatTile(
                label: 'ANR rate',
                leading: logo,
                semanticLabel: spoken('ANR rate'),
                value: switch (value.anrRate) {
                  final rate? => formatRate(rate),
                  null => null,
                },
                unrecorded: 'too little data',
                caption: window,
                tooltip:
                    'The share of daily users who saw the app stop '
                    'responding.',
              ),
            );
        case final ReadingMissing<VitalsSummary> missing:
          if (!missing.expected) {
            tiles.add(
              StatTile(
                label: 'Crash and ANR',
                leading: logo,
                semanticLabel: spoken('Crash and ANR'),
                value: null,
                unrecorded: _unavailable,
              ),
            );
          }
          note('Crash and ANR rates', missing);
      }

      switch (snapshot.downloads) {
        case ReadingValue(:final value):
          tiles.add(
            StatTile(
              label: '${value.unit} 14 d',
              leading: logo,
              semanticLabel: spoken('${value.unit} 14 d'),
              value: value.days.isEmpty
                  ? null
                  : formatCompactCount(value.total),
              unrecorded: 'none reported yet',
              caption: value.days.isEmpty
                  ? null
                  : 'to ${formatReportDay(value.days.last.day)}',
              tooltip: 'Stores report downloads a day or more late.',
            ),
          );
        case final ReadingMissing<DownloadSeries> missing:
          if (!missing.expected) {
            tiles.add(
              StatTile(
                label: 'Downloads',
                leading: logo,
                semanticLabel: spoken('Downloads'),
                value: null,
                unrecorded: _unavailable,
              ),
            );
          }
          note('Downloads', missing);
      }

      final allTimeLabel = store == StoreKind.appStore
          ? 'All-time downloads'
          : 'All-time installs';
      switch (snapshot.allTimeInstalls) {
        case null:
          break;
        case ReadingValue(:final value, :final checkedAt):
          tiles.add(
            StatTile(
              label: allTimeLabel,
              leading: logo,
              semanticLabel: spoken(allTimeLabel),
              value: formatInstallFigure(value),
              caption: describeInstallMeasure(value),
              tooltip: describeInstallTotal(value, store, readAt: checkedAt),
            ),
          );
        case final ReadingMissing<InstallTotal> missing:
          if (!missing.expected) {
            tiles.add(
              StatTile(
                label: allTimeLabel,
                leading: logo,
                semanticLabel: spoken(allTimeLabel),
                value: null,
                unrecorded: _unavailable,
              ),
            );
          }
          note(allTimeLabel, missing);
      }
    }
    return _Stack(
      children: [
        if (tiles.isNotEmpty)
          StatTileGrid(tiles: tiles, maxColumns: maxColumns),
        if (notes.isNotEmpty) _MissingNotes(notes: notes),
      ],
    );
  }
}

/// What a store could not give, a block per store under its logo and name.
class _MissingNotes extends StatelessWidget {
  const _MissingNotes({required this.notes});

  final Map<StoreKind, List<Widget>> notes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, MapEntry(key: store, value: lines))
              in notes.entries.indexed) ...[
            if (i > 0) const SizedBox(height: Insets.md),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: StoreLogo.named(
                store,
                size: Chrome.iconAction,
                color: scheme.onSurface,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            for (final line in lines)
              Padding(
                padding: const EdgeInsets.only(top: Insets.xs),
                child: line,
              ),
          ],
        ],
      ),
    );
  }
}

class _DownloadsChart extends StatelessWidget {
  const _DownloadsChart({
    required this.store,
    required this.series,
    required this.height,
  });

  /// Named when the app is on both stores.
  final StoreKind? store;
  final DownloadSeries series;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final days = series.days;
    final peak = days.fold(0, (most, day) => math.max(most, day.count));
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final store = this.store;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: Insets.sm,
            runSpacing: Insets.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (store != null)
                StoreLogo.named(
                  store,
                  size: Chrome.iconAction,
                  color: scheme.onSurface,
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              Text(
                '${formatCompactCount(series.total)} '
                '${series.unit.toLowerCase()} over ${days.length} reported '
                'days',
                style: muted,
              ),
            ],
          ),
          const SizedBox(height: Insets.sm),
          TimeSeriesChart(
            points: [
              for (final day in days)
                TimeSeriesPoint(day.day, day.count.toDouble()),
            ],
            start: days.first.day,
            end: days.last.day,
            // Headroom over the tallest day; one, so a flat zero has a scale.
            maxY: math.max(1.0, peak * 1.1),
            color: scheme.primary,
            height: height,
            semanticsLabel: [
              ?store?.label,
              '${series.unit} per day',
            ].join(' · '),
            valueLabel: (value) => formatCompactCount(value.round()),
            timeLabel: formatReportDay,
          ),
        ],
      ),
    );
  }
}
