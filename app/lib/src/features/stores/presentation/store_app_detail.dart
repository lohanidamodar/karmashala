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
import 'store_changes_view.dart';
import 'store_combine.dart';
import 'store_detail_errors.dart';
import 'store_detail_releases.dart';
import 'store_detail_reviews.dart';
import 'store_history_charts.dart';
import 'store_installs.dart';
import 'store_release_timeline.dart';
import 'stores_format.dart';

part 'store_app_detail/header.dart';
part 'store_app_detail/numbers.dart';
part 'store_app_detail/releases_signals.dart';

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
    return StoreSeenOnOpen(
      group: group,
      child: LayoutBuilder(
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
      ),
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
    final timeline = read
        ? _Section(
            'Release timeline',
            key: const ValueKey('release-timeline'),
            child: StoreReleaseTimelines(group: group),
          )
        : null;
    final overTime = read
        ? _Section(
            'Over time',
            key: const ValueKey('over-time'),
            child: StoreHistoryCharts(
              group: group,
              narrow: layout == _Layout.narrow,
            ),
          )
        : null;
    final numbersSide = [?numbers, ?downloads, ?overTime];

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
          ?timeline,
          ...numbersSide,
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Actions(group: group),
        if (group.changes.isNotEmpty)
          _Section(
            'What changed',
            key: const ValueKey('what-changed'),
            child: _Card(child: StoreWhatChanged(group: group)),
          ),
        status,
        // Full width beside two columns, so its steps can run across.
        if (wide && numbersSide.isNotEmpty) ?timeline,
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
