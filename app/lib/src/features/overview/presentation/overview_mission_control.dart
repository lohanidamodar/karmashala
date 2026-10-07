import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../explorer/application/agent_state_providers.dart';
import '../application/overview_board.dart';
import '../application/overview_prefs.dart';
import '../application/overview_providers.dart';
import '../application/overview_tiles.dart';
import 'overview_counters.dart';
import 'overview_filters.dart';
import 'overview_project_tile.dart';

/// The mark ids as drawn, tile by tile — what the arrow keys move over.
List<List<String>> drawnMarks(OverviewBoard board) => [
  for (final lane in arrangeTiles(board.lanes).live)
    [for (final card in marksOf(lane)) card.id],
];

/// **Mission control**: the live counters, the filters set, then one tile
/// per project (or machine) by attention, and the quiet ones folded into a
/// line at the end.
class OverviewMissionControl extends ConsumerWidget {
  const OverviewMissionControl({required this.onOpen, super.key});

  /// A mark or a headline was tapped: peek it.
  final ValueChanged<OverviewCard> onOpen;

  /// The narrowest a tile is drawn at 1x text, and the most across.
  static const _tileMin = 320.0;
  static const _quietMin = 200.0;
  static const _maxColumns = 4;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final board = ref.watch(overviewBoardProvider);
    final groupBy = ref.watch(overviewPrefsProvider.select((p) => p.groupBy));
    final columns = ref.watch(
      overviewPrefsProvider.select((p) => p.filter.columns),
    );
    final (:strip, :doneToday) = ref.watch(overviewCountersProvider);
    final hidden = ref.watch(agentsHiddenWorkingCountProvider);
    final hasFilters = ref.watch(overviewActiveFiltersProvider).isNotEmpty;
    final quietOpen = ref.watch(
      overviewTileFoldsProvider.select((f) => f.quietOpen),
    );
    final tiles = arrangeTiles(board.lanes);
    final live = strip.needsYou + strip.failed + strip.working + strip.ready;
    final calm = live == 0 && hidden == 0 && columns == null;
    final hasFacts =
        strip.spendRecorded ||
        strip.failingChecks > 0 ||
        strip.usageLimitHits > 0;
    final noun = groupBy == OverviewGroupBy.project ? 'project' : 'machine';
    String plural(int n) => n == 1 ? noun : '${noun}s';

    return LayoutBuilder(
      builder: (context, box) {
        final scaler = MediaQuery.textScalerOf(context);
        final gutter = box.maxWidth < WidthClass.mediumMin
            ? Insets.lg
            : Insets.xl;
        final inner = box.maxWidth - gutter * 2;
        int across(double min) =>
            ((inner + Insets.md) /
                    (WidthClass.scaleBreakpoint(min, scaler) + Insets.md))
                .floor()
                .clamp(1, _maxColumns);

        final items = <Widget>[
          if (calm)
            _CalmState(doneToday: doneToday)
          else
            const OverviewCounters(),
          if (hasFilters)
            const Padding(
              padding: EdgeInsets.only(top: Insets.md),
              child: OverviewActiveFilterChips(),
            ),
          if (hasFacts)
            const Padding(
              padding: EdgeInsets.only(top: Insets.sm),
              child: OverviewFactsLine(),
            ),
          if (tiles.live.isNotEmpty) ...[
            const SizedBox(height: Insets.xl),
            EyebrowLabel(
              '${tiles.live.length} ${plural(tiles.live.length)}',
              padding: const EdgeInsets.only(bottom: Insets.sm),
            ),
            ..._grid(
              [
                for (final lane in tiles.live)
                  OverviewProjectTile(
                    key: ValueKey('overview-lane:${lane.key}'),
                    lane: lane,
                    groupBy: groupBy,
                    onOpen: onOpen,
                  ),
              ],
              across(_tileMin),
              Insets.md,
            ),
          ] else if (columns != null)
            Padding(
              padding: const EdgeInsets.only(top: Insets.xl),
              child: Text(
                'Nothing here right now.',
                key: const ValueKey('overview-none-in-state'),
                style: UiDensity.of(context).muted(Theme.of(context)),
              ),
            ),
          if (tiles.quiet.isNotEmpty) ...[
            const SizedBox(height: Insets.md),
            _FoldLine(
              key: const ValueKey('overview-quiet-lanes'),
              label:
                  '${tiles.quiet.length} quiet ${plural(tiles.quiet.length)}',
              open: quietOpen,
              onTap: ref.read(overviewTileFoldsProvider.notifier).toggleQuiet,
            ),
            if (quietOpen) ...[
              const SizedBox(height: Insets.sm),
              ..._grid(
                [
                  for (final lane in tiles.quiet)
                    OverviewQuietTile(lane: lane, onOpen: onOpen),
                ],
                across(_quietMin) + 1,
                Insets.sm,
              ),
            ],
          ],
        ];
        return ListView(
          key: const ValueKey('overview-mission'),
          padding: EdgeInsets.fromLTRB(gutter, Insets.md, gutter, Insets.xxl),
          children: items,
        );
      },
    );
  }

  /// [tiles] in rows of [across], each tile its own height.
  static List<Widget> _grid(List<Widget> tiles, int across, double gap) => [
    for (var start = 0; start < tiles.length; start += across)
      Padding(
        padding: EdgeInsets.only(bottom: gap),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = start; i < start + across; i++) ...[
              if (i > start) SizedBox(width: gap),
              Expanded(
                child: i < tiles.length ? tiles[i] : const SizedBox.shrink(),
              ),
            ],
          ],
        ),
      ),
  ];
}

/// Nothing live anywhere: one calm line, and what finished today.
class _CalmState extends ConsumerWidget {
  const _CalmState({required this.doneToday});

  final int doneToday;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final density = UiDensity.of(context);
    return Container(
      key: const ValueKey('overview-calm'),
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.lg,
        vertical: Insets.md,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      child: Wrap(
        spacing: Insets.md,
        runSpacing: Insets.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                AppIcons.checkCircle,
                size: density.icon,
                color: SemanticColors.of(context).idle,
              ),
              const SizedBox(width: Insets.sm),
              Flexible(
                child: Text(
                  'All quiet: nothing is running or waiting on you.',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          TextButton(
            key: const ValueKey('overview-calm-done'),
            onPressed: doneToday == 0
                ? null
                : () => ref.read(overviewPrefsProvider.notifier).setColumns(
                    const {BoardColumn.done},
                  ),
            child: Text('$doneToday done today'),
          ),
        ],
      ),
    );
  }
}

/// "4 quiet projects ▸".
class _FoldLine extends StatelessWidget {
  const _FoldLine({
    required this.label,
    required this.open,
    required this.onTap,
    super.key,
  });

  final String label;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Semantics(
      button: true,
      expanded: open,
      label: label,
      excludeSemantics: true,
      child: Align(
        alignment: Alignment.centerLeft,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(Radii.sm),
          child: TouchTarget(
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Insets.xs,
                vertical: Insets.xs,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(color: muted),
                    ),
                  ),
                  const SizedBox(width: Insets.xs),
                  Icon(
                    open ? AppIcons.caretDown : AppIcons.caretRight,
                    size: UiDensity.of(context).iconSmall,
                    color: muted,
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
