import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/rows.dart' show compactAge;
import 'package:karmashala_ui/tokens.dart';

import '../application/overview_board.dart' show OverviewLane;
import '../application/overview_drawer.dart';
import '../application/overview_providers.dart';
import '../application/overview_tree.dart';
import 'overview_counters.dart';
import 'overview_strip.dart';
import 'overview_triage.dart';

/// **The phone dashboard's one strip** (round 121): what waits on the owner
/// (the waiting drawer, as a sheet), what is new (the next new session, as
/// U does), Today's other counts, then the lane chips — one row of compact
/// chips that slides sideways. It took the place of round 118's bottom bar
/// and the separate row of lane chips.
class OverviewPhoneStrip extends ConsumerWidget {
  const OverviewPhoneStrip({
    required this.waiting,
    required this.fresh,
    required this.lanes,
    required this.onScreen,
    required this.onLane,
    super.key,
  });

  /// How many wait on the owner, and how many sessions are new.
  final int waiting;
  final int fresh;

  final List<(OverviewLane, List<OverviewTreeNode>)> lanes;

  /// The lane on screen, whose chip is lit.
  final String? onScreen;
  final ValueChanged<String> onLane;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final semantic = SemanticColors.of(context);
    final drawer = ref.watch(overviewDrawerProvider.select((d) => d.open));
    final wait = ref.watch(overviewTodayProvider.select((t) => t.oldestWait));
    final drawers = ref.read(overviewDrawerProvider.notifier);
    final sheets = ref.read(overviewSearchSheetProvider.notifier);
    return SingleChildScrollView(
      key: const ValueKey('overview-strip'),
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          OverviewCountChip(
            key: const ValueKey('overview-strip-waiting'),
            count: waiting,
            label: 'waiting',
            caption: waiting > 0 && wait != null ? compactAge(wait) : null,
            hue: semantic.attention,
            selected: drawer,
            spoken: [
              '$waiting waiting on you',
              if (waiting > 0 && wait != null) 'oldest ${compactAge(wait)}',
              drawer ? 'tap to close the list' : 'tap to list them',
            ].join(', '),
            onTap: () {
              sheets.close();
              drawers.toggle();
            },
          ),
          if (fresh > 0) ...[
            const SizedBox(width: Insets.xs),
            OverviewCountChip(
              key: const ValueKey('overview-strip-next-new'),
              count: fresh,
              label: 'new',
              hue: semantic.unread,
              spoken: '$fresh new, tap to go to the next',
              onTap: () {
                sheets.close();
                FocusManager.instance.primaryFocus?.unfocus();
                Actions.maybeInvoke(context, const OverviewNextNewIntent());
              },
            ),
          ],
          const SizedBox(width: Insets.xs),
          // Waiting stands for Today's "needs you" here.
          const OverviewTodayStrip(compact: true, withNeedsYou: false),
          if (lanes.isNotEmpty) ...[
            const SizedBox(width: Insets.xs),
            SizedBox(
              height: Touch.iconSmall,
              child: VerticalDivider(
                width: Insets.sm,
                thickness: Insets.hair,
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            const SizedBox(width: Insets.xs),
            OverviewLaneChipRow(
              lanes: lanes,
              onScreen: onScreen,
              onTap: onLane,
            ),
          ],
        ],
      ),
    );
  }
}

/// A count in the phone's strip: the number in its [hue] and a word, lit
/// while what it opens is open.
class OverviewCountChip extends StatelessWidget {
  const OverviewCountChip({
    required this.count,
    required this.label,
    required this.hue,
    required this.spoken,
    required this.onTap,
    this.caption,
    this.selected = false,
    super.key,
  });

  final int count;
  final String label;
  final Color hue;
  final String spoken;
  final VoidCallback onTap;

  /// A short fact after the word, in [hue]: the oldest wait.
  final String? caption;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final live = count > 0;
    final radius = BorderRadius.circular(Radii.sm);
    final caption = this.caption;
    return Semantics(
      button: true,
      selected: selected,
      label: spoken,
      excludeSemantics: true,
      child: Material(
        color: selected ? StateLayers.selected(scheme) : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: StateLayers.focusRingWidth,
          ),
        ),
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: overviewCompactChipHeight(context),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$count',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: live ? hue : scheme.onSurfaceVariant,
                      fontWeight: live ? FontWeight.w700 : FontWeight.w400,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(width: Insets.xs),
                  Text(
                    label,
                    maxLines: 1,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: live ? scheme.onSurface : scheme.onSurfaceVariant,
                    ),
                  ),
                  if (caption != null) ...[
                    const SizedBox(width: Insets.xs),
                    Text(
                      caption,
                      maxLines: 1,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: hue,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
