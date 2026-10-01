import 'package:flutter/material.dart';
import 'package:karmashala_ui/charts.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:store_console/store_console.dart';

import '../application/store_groups.dart';
import 'stores_format.dart';

/// One app on the dashboard: its name, and a row per store it is on.
class StoreGroupCard extends StatelessWidget {
  const StoreGroupCard({
    required this.group,
    required this.onTap,
    this.selected = false,
    super.key,
  });

  final StoreAppGroup group;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected
            ? SurfaceTones.of(context).selected
            : scheme.surfaceContainerLow,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          side: BorderSide(
            color: selected ? scheme.primary : scheme.outlineVariant,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(Insets.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  group.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
                Text(
                  group.bundleId,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                for (final entry in group.entries) ...[
                  const SizedBox(height: Insets.md),
                  StoreEntryRow(entry: entry),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One store's line on a card: what is live, what is pending, the rating and
/// the downloads.
class StoreEntryRow extends StatelessWidget {
  const StoreEntryRow({required this.entry, super.key});

  final StoreEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final snapshot = entry.snapshot;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                entry.app.store.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium,
              ),
            ),
            const SizedBox(width: Insets.sm),
            if (snapshot == null)
              Text('Not read yet', style: muted)
            else
              _LiveVersion(snapshot: snapshot),
          ],
        ),
        if (snapshot != null) ...[
          const SizedBox(height: Insets.xs),
          Wrap(
            spacing: Insets.md,
            runSpacing: Insets.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (entry.pending case final release?)
                ReleaseStateLabel(release: release),
              switch (snapshot.rating) {
                ReadingValue(:final value) => Text(
                  formatRating(value),
                  style: theme.textTheme.bodySmall,
                ),
                ReadingMissing(:final message) => MissingDash(
                  what: 'Rating',
                  reason: message,
                ),
              },
              switch (snapshot.downloads) {
                ReadingValue(:final value) => _Downloads(series: value),
                ReadingMissing(:final message) => MissingDash(
                  what: 'Downloads',
                  reason: message,
                ),
              },
            ],
          ),
        ],
      ],
    );
  }
}

class _LiveVersion extends StatelessWidget {
  const _LiveVersion({required this.snapshot});

  final StoreAppSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final releases = snapshot.releases;
    if (releases is ReadingMissing<List<StoreRelease>>) {
      return MissingDash(what: 'Live version', reason: releases.message);
    }
    final live = snapshot.live;
    return Text(
      live == null ? 'Not live' : formatVersion(live),
      style: theme.textTheme.bodySmall?.copyWith(
        color: live == null ? theme.colorScheme.onSurfaceVariant : null,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

class _Downloads extends StatelessWidget {
  const _Downloads({required this.series});

  final DownloadSeries series;

  /// Wide enough to show fourteen days as a shape, narrow enough for a card.
  static const sparklineWidth = 56.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (series.days.isEmpty) {
      return Text(
        'No ${series.unit.toLowerCase()} reported yet',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Sparkline(
          values: [for (final day in series.days) day.count.toDouble()],
          color: theme.colorScheme.primary,
          width: sparklineWidth,
          semanticsLabel: '${series.unit} per day',
        ),
        const SizedBox(width: Insets.xs),
        Text(
          '${formatCompactCount(series.total)} in 14 d',
          style: theme.textTheme.bodySmall?.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

/// A release's state as a dot and its words: the attention colour when
/// somebody has to act, the working colour while it is on its way.
class ReleaseStateLabel extends StatelessWidget {
  const ReleaseStateLabel({required this.release, super.key});

  final StoreRelease release;

  @override
  Widget build(BuildContext context) {
    final semantic = SemanticColors.of(context);
    final state = release.state;
    final (color, meaning) = state.needsAttention
        ? (semantic.attention, 'Needs attention')
        : state.inFlight
        ? (semantic.working, 'In progress')
        : (semantic.neutral, 'Settled');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        StatusDot(color: color, label: meaning),
        const SizedBox(width: Insets.xs),
        Flexible(
          child: Text(
            formatReleaseState(release),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

/// A reading the store did not give: a muted dash with the reason on hover.
/// Never a zero, never a guess (PROJECT.md §19).
class MissingDash extends StatelessWidget {
  const MissingDash({required this.what, required this.reason, super.key});

  final String what;
  final String reason;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: '$what: $reason',
      child: Semantics(
        label: '$what not available. $reason',
        child: ExcludeSemantics(
          child: Text(
            '$what —',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// A missing reading said inline in the detail: quietly when it is the
/// store's or the setup's doing, in the warning tone when it is a fault.
class MissingReadingLine extends StatelessWidget {
  const MissingReadingLine({
    required this.what,
    required this.reading,
    super.key,
  });

  final String what;
  final ReadingMissing<Object?> reading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = '$what — ${reading.message}';
    if (reading.expected) {
      return Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          AppIcons.warning,
          size: Chrome.iconSmall,
          color: SemanticColors.of(context).attention,
        ),
        const SizedBox(width: Insets.xs),
        Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
      ],
    );
  }
}
