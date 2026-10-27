import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/widgets/adaptive_modal.dart';
import '../../explorer/application/agent_states.dart';
import '../../sessions/presentation/prompt_cards/question_prompt_card.dart';
import '../application/overview_board.dart';
import '../application/overview_drawer.dart';
import '../application/overview_tree.dart';
import 'overview_card_links.dart';
import 'overview_card_parts.dart';
import 'overview_counters.dart';
import 'overview_done_card.dart';
import 'overview_queue_card.dart';

/// **The dashboard's slim strip**: Today's counts, the search field, New and
/// Pinned (which dim the rest), Waiting N (the drawer) and More (the
/// heartbeat, glances and lanes under it). Narrow, the controls wrap under
/// the counts.
class OverviewTopStrip extends ConsumerWidget {
  const OverviewTopStrip({required this.waiting, super.key});

  /// How many wait on the owner: the Waiting button's count.
  final int waiting;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final highlight = ref.watch(overviewHighlightProvider);
    final drawer = ref.watch(overviewDrawerProvider.select((d) => d.open));
    final more = ref.watch(overviewMoreProvider);
    final lit = ref.read(overviewHighlightProvider.notifier);
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, box) {
        final wide =
            box.maxWidth >=
            WidthClass.scaleBreakpoint(WidthClass.expandedMin, scaler);
        final searchWidth = WidthClass.scaleBreakpoint(
          Chrome.stripSearchWidth,
          scaler,
        ).clamp(0.0, box.maxWidth);
        const counts = SingleChildScrollView(
          key: ValueKey('overview-strip-counts'),
          scrollDirection: Axis.horizontal,
          child: OverviewTodayStrip(compact: true),
        );
        final controls = <Widget>[
          SizedBox(
            width: searchWidth,
            child: SearchField(
              key: const ValueKey('overview-search'),
              decoration: compactSearchDecoration(hintText: 'Search sessions'),
            ),
          ),
          _StripToggle(
            key: const ValueKey('overview-strip-new'),
            label: 'New',
            selected: highlight == OverviewHighlight.fresh,
            onTap: () => lit.toggle(OverviewHighlight.fresh),
          ),
          _StripToggle(
            key: const ValueKey('overview-strip-pinned'),
            label: 'Pinned',
            icon: AppIcons.pushPin,
            selected: highlight == OverviewHighlight.pinned,
            onTap: () => lit.toggle(OverviewHighlight.pinned),
          ),
          _StripToggle(
            key: const ValueKey('overview-waiting-toggle'),
            label: 'Waiting $waiting',
            selected: drawer,
            hot: waiting > 0,
            onTap: ref.read(overviewDrawerProvider.notifier).toggle,
          ),
          _StripToggle(
            key: const ValueKey('overview-more-toggle'),
            label: more ? 'More ▾' : 'More ▸',
            selected: more,
            onTap: ref.read(overviewMoreProvider.notifier).toggle,
          ),
        ];
        if (wide) {
          return Row(
            key: const ValueKey('overview-strip'),
            children: [
              const Expanded(child: counts),
              for (final control in controls) ...[
                const SizedBox(width: Insets.xs),
                control,
              ],
            ],
          );
        }
        return Column(
          key: const ValueKey('overview-strip'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            counts,
            const SizedBox(height: Insets.xs),
            Wrap(
              spacing: Insets.xs,
              runSpacing: Insets.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: controls,
            ),
          ],
        );
      },
    );
  }
}

/// One of the strip's toggles: lit while [selected]; [hot] tints it while
/// something waits.
class _StripToggle extends StatelessWidget {
  const _StripToggle({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.hot = false,
    super.key,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final bool hot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final density = UiDensity.of(context);
    final ink = hot ? SemanticColors.of(context).attention : scheme.onSurface;
    final radius = BorderRadius.circular(Radii.sm);
    return Semantics(
      button: true,
      toggled: selected,
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
              minHeight: density.isTouch ? Touch.target : Chrome.control,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon case final icon?) ...[
                    Icon(icon, size: density.iconSmall, color: ink),
                    SizedBox(width: density.glyphGap),
                  ],
                  Text(
                    label,
                    maxLines: 1,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: ink,
                      fontWeight: hot ? FontWeight.w600 : null,
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

/// **The lane chips** under the strip: one per lane, with its asks and a
/// dot for what is new. A tap scrolls to the lane; the lane on screen is
/// lit.
class OverviewLaneChips extends StatelessWidget {
  const OverviewLaneChips({
    required this.lanes,
    required this.onScreen,
    required this.onTap,
    super.key,
  });

  final List<(OverviewLane, List<OverviewTreeNode>)> lanes;
  final String? onScreen;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    key: const ValueKey('overview-lane-chips'),
    scrollDirection: Axis.horizontal,
    child: Row(
      children: [
        for (final (i, (lane, trees)) in lanes.indexed) ...[
          if (i > 0) const SizedBox(width: Insets.xs),
          _LaneChip(
            lane: lane,
            trees: trees,
            selected: lane.key == onScreen,
            onTap: () => onTap(lane.key),
          ),
        ],
      ],
    ),
  );
}

class _LaneChip extends ConsumerWidget {
  const _LaneChip({
    required this.lane,
    required this.trees,
    required this.selected,
    required this.onTap,
  });

  final OverviewLane lane;
  final List<OverviewTreeNode> trees;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final density = UiDensity.of(context);
    final asks = trees.fold(0, (sum, tree) => sum + overviewWaitingIn(tree));
    final fresh = [
      for (final tree in trees) ...tree.drawn,
    ].any((card) => watchOverviewNewCount(ref, card) > 0);
    final radius = BorderRadius.circular(Radii.pill);
    return Semantics(
      button: true,
      selected: selected,
      label: [
        lane.label,
        if (asks > 0) '$asks ${asks == 1 ? 'ask' : 'asks'}',
        if (fresh) 'new',
      ].join(', '),
      excludeSemantics: true,
      child: Material(
        key: ValueKey('overview-lane-chip:${lane.key}'),
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
              minHeight: density.isTouch ? Touch.target : Chrome.control,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.md),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    lane.label.isEmpty ? 'Unfiled' : lane.label,
                    maxLines: 1,
                    style: theme.textTheme.labelMedium,
                  ),
                  if (fresh) ...[
                    const SizedBox(width: Insets.xs),
                    Container(
                      key: ValueKey('overview-lane-new:${lane.key}'),
                      width: Chrome.dot,
                      height: Chrome.dot,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                  if (asks > 0) ...[
                    const SizedBox(width: Insets.xs),
                    Text(
                      '$asks',
                      key: ValueKey('overview-lane-asks:${lane.key}'),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: semantic.attention,
                        fontWeight: FontWeight.w700,
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

/// A lane's header: its name and count, "Archive done · N" for its ended
/// families, and "N archived today", which lists them.
class OverviewLaneHeader extends ConsumerWidget {
  const OverviewLaneHeader({
    required this.lane,
    required this.trees,
    super.key,
  });

  final OverviewLane lane;
  final List<OverviewTreeNode> trees;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final compact = UiDensity.of(context).compactButton;
    final done = [
      for (final tree in trees)
        if (tree.card.state == AgentState.ended &&
            overviewFamilyToArchive(tree).isNotEmpty)
          tree,
    ];
    final archived = ref.watch(
      overviewArchivedTodayProvider.select((a) => a[lane.key] ?? const []),
    );
    return Padding(
      padding: const EdgeInsets.only(top: Insets.xs, bottom: Insets.sm),
      child: Wrap(
        spacing: Insets.sm,
        runSpacing: Insets.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            '${lane.label} · ${trees.length}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          if (done.isNotEmpty)
            TextButton(
              key: ValueKey('overview-lane-archive:${lane.key}'),
              style: compact,
              onPressed: () {
                for (final tree in done) {
                  unawaited(archiveFamilyFromDashboard(context, ref, tree));
                }
              },
              child: Text('Archive done · ${done.length}'),
            ),
          if (archived.isNotEmpty)
            Builder(
              builder: (button) => TextButton(
                key: ValueKey('overview-lane-archived:${lane.key}'),
                style: compact,
                onPressed: () => showAdaptivePopover<void>(
                  context: button,
                  title: 'Archived today',
                  builder: (_) => _ArchivedList(titles: archived),
                ),
                child: Text('${archived.length} archived today ▸'),
              ),
            ),
        ],
      ),
    );
  }
}

class _ArchivedList extends StatelessWidget {
  const _ArchivedList({required this.titles});

  final List<String> titles;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(Insets.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final title in titles)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Insets.xs),
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
            ),
          const SizedBox(height: Insets.sm),
          Text(
            "Restore one from the session's menu in the lists.",
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// **The waiting drawer**: what waits on the owner, answerable in place, in
/// the queue's order — over the board, so the lanes never move. [sheet]
/// draws it as a phone's bottom sheet.
class OverviewWaitingDrawer extends ConsumerWidget {
  const OverviewWaitingDrawer({
    required this.queue,
    required this.forest,
    required this.onOpen,
    this.sheet = false,
    this.onEdit,
    this.onTerminal,
    this.onAnswered,
    this.questionControllerOf,
    super.key,
  });

  final List<OverviewCard> queue;
  final OverviewForest forest;
  final ValueChanged<OverviewCard> onOpen;
  final bool sheet;
  final ValueChanged<OverviewCard>? onEdit;
  final ValueChanged<OverviewCard>? onTerminal;
  final ValueChanged<OverviewCard>? onAnswered;
  final QuestionPromptController Function(String id)? questionControllerOf;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final family = ref.watch(overviewDrawerProvider.select((d) => d.family));
    final root = family == null
        ? null
        : [
            for (final (_, trees) in forest.lanes)
              for (final tree in trees)
                if (tree.card.id == family) tree,
          ].firstOrNull;
    final members = root == null
        ? null
        : {for (final card in root.drawn) card.id};
    final list = members == null
        ? queue
        : [
            for (final card in queue)
              if (members.contains(card.id)) card,
          ];
    final controller = ref.read(overviewDrawerProvider.notifier);
    final title = root == null
        ? 'Waiting on you · ${list.length}'
        : '${root.card.entry.title} asks · ${list.length}';
    final radius = sheet
        ? const BorderRadius.vertical(top: Radius.circular(Radii.sheet))
        : BorderRadius.circular(Radii.lg);
    return Material(
      key: const ValueKey('overview-waiting-drawer'),
      elevation: Elevations.dialog,
      color: scheme.surfaceContainerLow,
      shadowColor: scheme.shadow,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Insets.md,
              Insets.xs,
              Insets.xs,
              Insets.xs,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    key: const ValueKey('overview-drawer-title'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (root != null)
                  TextButton(
                    key: const ValueKey('overview-drawer-all'),
                    style: UiDensity.of(context).compactButton,
                    onPressed: controller.showAll,
                    child: const Text('Show all'),
                  ),
                IconButton(
                  key: const ValueKey('overview-drawer-close'),
                  tooltip: 'Close',
                  onPressed: controller.close,
                  icon: const Icon(AppIcons.x),
                ),
              ],
            ),
          ),
          const Divider(height: Insets.hair),
          Expanded(
            child: list.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(Insets.lg),
                      child: Text(
                        'Nothing is waiting on you.',
                        key: const ValueKey('overview-drawer-empty'),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  )
                : ListView(
                    key: const ValueKey('overview-queue'),
                    padding: const EdgeInsets.all(Insets.md),
                    children: [
                      for (final card in list)
                        Padding(
                          padding: const EdgeInsets.only(bottom: Insets.md),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              OverviewParentLink(card: card),
                              OverviewFamilyHover(
                                card: card,
                                child: OverviewQueueCard(
                                  key: ValueKey(
                                    'overview-queue-card:${card.id}',
                                  ),
                                  card: card,
                                  onOpen: onOpen,
                                  onEdit: onEdit,
                                  onTerminal: onTerminal,
                                  onAnswered: onAnswered,
                                  questionController: questionControllerOf
                                      ?.call(card.id),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
