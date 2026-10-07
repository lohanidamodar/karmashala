import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/util/clock_provider.dart';
import '../../environments/application/environments_controller.dart';
import '../../explorer/application/agent_states.dart';
import '../../sessions/application/session_status_providers.dart';
import '../application/overview_board.dart';
import '../application/overview_providers.dart';
import '../application/overview_tiles.dart';
import 'overview_session_mark.dart';

/// Which tiles show every mark rather than the capped row, and whether the
/// quiet ones are open. Ephemeral: mission control opens folded.
@immutable
class OverviewTileFolds {
  const OverviewTileFolds({this.quietOpen = false, this.expanded = const {}});

  final bool quietOpen;
  final Set<String> expanded;
}

class OverviewTileFoldsController extends Notifier<OverviewTileFolds> {
  @override
  OverviewTileFolds build() => const OverviewTileFolds();

  void toggleQuiet() => state = OverviewTileFolds(
    quietOpen: !state.quietOpen,
    expanded: state.expanded,
  );

  void expand(String laneKey) => state = OverviewTileFolds(
    quietOpen: state.quietOpen,
    expanded: {...state.expanded, laneKey},
  );
}

final overviewTileFoldsProvider =
    NotifierProvider.autoDispose<
      OverviewTileFoldsController,
      OverviewTileFolds
    >(OverviewTileFoldsController.new);

/// The icon for a machine of [kind].
IconData machineGlyph(OverviewMachineKind? kind) => switch (kind) {
  OverviewMachineKind.wsl => AppIcons.terminal,
  OverviewMachineKind.ssh => AppIcons.globe,
  _ => AppIcons.house,
};

/// **One project (or machine) on mission control**: its name and machines,
/// a row of session marks, the one session that matters most, and a footer
/// that counts the rest.
class OverviewProjectTile extends ConsumerWidget {
  const OverviewProjectTile({
    required this.lane,
    required this.groupBy,
    required this.onOpen,
    super.key,
  });

  final OverviewLane lane;
  final OverviewGroupBy groupBy;
  final ValueChanged<OverviewCard> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tones = SurfaceTones.of(context);
    final semantic = SemanticColors.of(context);
    final density = UiDensity.of(context);
    final marks = marksOf(lane);
    final statusOf = ref.read(sessionStatusLookupProvider);
    // Woken by any mark's status, so the headline follows the oldest wait.
    for (final card in lane.cards(BoardColumn.needsYou)) {
      ref.watch(agentSessionStatusProvider(card.id));
    }
    final headline = headlineOf(
      lane,
      waitingSince: (id) => statusOf(id)?.waitingSince,
    );
    final needsYou = lane.cards(BoardColumn.needsYou).isNotEmpty;
    final working = lane
        .cards(BoardColumn.working)
        .any((c) => c.state == AgentState.working);
    final rail = needsYou
        ? semantic.attention
        : working
        ? semantic.working
        : null;
    final footer = tileFooter(lane, now: ref.read(clockProvider).nowUtc());
    final pad = density.isTouch ? Insets.lg : Insets.md;

    final content = Padding(
      padding: EdgeInsets.fromLTRB(pad + Insets.xs, pad, pad, pad),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _Header(lane: lane, groupBy: groupBy, marks: marks),
          const SizedBox(height: Insets.md),
          _MarksRow(lane: lane, marks: marks, groupBy: groupBy, onOpen: onOpen),
          if (headline != null) ...[
            const SizedBox(height: Insets.md),
            _Headline(card: headline, onTap: () => onOpen(headline)),
          ],
          const SizedBox(height: Insets.sm),
          Text(
            footer,
            key: ValueKey('overview-tile-footer:${lane.key}'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: density
                .muted(theme)
                ?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        ],
      ),
    );

    return Semantics(
      container: true,
      label: '${lane.label}: $footer',
      child: Material(
        key: ValueKey('overview-tile:${lane.key}'),
        color: scheme.surfaceContainerLow,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.lg),
          side: BorderSide(
            color: needsYou ? tones.attentionEdge : scheme.outlineVariant,
          ),
        ),
        child: Stack(
          children: [
            content,
            if (rail != null)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: Insets.xs - Insets.hair,
                child: ColoredBox(color: rail),
              ),
          ],
        ),
      ),
    );
  }
}

/// The name, and the machines its sessions run on (or, for a machine, its
/// kind).
class _Header extends ConsumerWidget {
  const _Header({
    required this.lane,
    required this.groupBy,
    required this.marks,
  });

  final OverviewLane lane;
  final OverviewGroupBy groupBy;
  final List<OverviewCard> marks;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final density = UiDensity.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final kinds = ref.watch(overviewMachineKindsProvider);
    OverviewMachineKind? kindOf(String id) => kinds[id];
    final machines = groupBy == OverviewGroupBy.machine
        ? const <String>[]
        : <String>{
            for (final card in marks) ?card.entry.directory?.environmentId,
          }.toList();
    Widget glyph(String id) {
      final label = ref.watch(environmentLabelForIdProvider(id));
      return Tooltip(
        message: label,
        excludeFromSemantics: true,
        child: Padding(
          padding: const EdgeInsets.only(left: Insets.xs),
          child: Icon(
            machineGlyph(kindOf(id)),
            size: density.iconSmall,
            color: muted,
            semanticLabel: label,
          ),
        ),
      );
    }

    return Row(
      children: [
        if (groupBy == OverviewGroupBy.machine) ...[
          Icon(
            machineGlyph(kindOf(lane.key)),
            size: density.icon,
            color: muted,
          ),
          const SizedBox(width: Insets.sm),
        ],
        Expanded(
          child: Text(
            lane.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        for (final id in machines.take(3)) glyph(id),
        if (machines.length > 3)
          Padding(
            padding: const EdgeInsets.only(left: Insets.xs),
            child: Text(
              '+${machines.length - 3}',
              style: theme.textTheme.labelSmall?.copyWith(color: muted),
            ),
          ),
      ],
    );
  }
}

/// The marks, capped at two rows with "+N", which shows the rest.
class _MarksRow extends ConsumerWidget {
  const _MarksRow({
    required this.lane,
    required this.marks,
    required this.groupBy,
    required this.onOpen,
  });

  final OverviewLane lane;
  final List<OverviewCard> marks;
  final OverviewGroupBy groupBy;
  final ValueChanged<OverviewCard> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(overviewFocusProvider.select((f) => f.selected));
    final expanded = ref.watch(
      overviewTileFoldsProvider.select((f) => f.expanded.contains(lane.key)),
    );
    final facts = ref.read(overviewFactsProvider);
    final projectNames = {for (final p in facts.projects) p.id: p.label};
    final density = UiDensity.of(context);
    // The mark, its ring of focus and the thumb's target, side by side.
    final slot = density.isTouch
        ? Touch.target
        : overviewMarkSize(density) + Insets.sm;
    final gap = density.isTouch ? Insets.sm : Insets.xs;
    return LayoutBuilder(
      builder: (context, box) {
        final perRow = ((box.maxWidth + gap) / (slot + gap)).floor();
        final at = marks.indexWhere((c) => c.id == selected);
        var (:shown, :more) = capMarks(marks.length, perRow: perRow);
        if (expanded || at >= shown) (shown, more) = (marks.length, 0);
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          crossAxisAlignment: WrapCrossAlignment.start,
          children: [
            for (final card in marks.take(shown))
              OverviewSessionMark(
                key: ValueKey('overview:${lane.key}:${card.id}'),
                card: card,
                selected: card.id == selected,
                projectLabel: groupBy == OverviewGroupBy.machine
                    ? projectNames[facts.projectOf(card.entry)]
                    : null,
                onTap: () => onOpen(card),
              ),
            if (more > 0)
              _MoreMarks(
                key: ValueKey('overview-more:${lane.key}'),
                count: more,
                onTap: () => ref
                    .read(overviewTileFoldsProvider.notifier)
                    .expand(lane.key),
              ),
          ],
        );
      },
    );
  }
}

class _MoreMarks extends StatelessWidget {
  const _MoreMarks({required this.count, required this.onTap, super.key});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = overviewMarkSize(UiDensity.of(context));
    return Semantics(
      button: true,
      label: '$count more sessions',
      excludeSemantics: true,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: TouchTarget(
          child: Padding(
            padding: const EdgeInsets.all(Insets.hair * 3),
            child: SizedBox.square(
              dimension: size,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: Center(
                  child: Text(
                    '+$count',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "⛨ Round 21 · asks: allow write …": the tile's one session that matters.
class _Headline extends ConsumerWidget {
  const _Headline({required this.card, required this.onTap});

  final OverviewCard card;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final density = UiDensity.of(context);
    final line = watchOverviewLine(ref, card);
    final wait = ref.read(sessionStatusLookupProvider)(card.id)?.waiting;
    final color = overviewStateColor(context, card.state);
    final size = density.icon;
    final glyph = switch (card.state) {
      AgentState.needsYou => NeedsYouGlyph(
        size: size,
        question: wait == AgentWaitKind.question,
      ),
      AgentState.working => WorkingSpinner(size: size, color: color!),
      AgentState.failed => Icon(AppIcons.xCircle, size: size, color: color),
      AgentState.ready => Icon(AppIcons.checkCircle, size: size, color: color),
      AgentState.quiet => Icon(
        AppIcons.pauseCircle,
        size: size,
        color: theme.colorScheme.onSurfaceVariant,
      ),
      AgentState.ended => Icon(
        AppIcons.checkCircle,
        size: size,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    };
    final text = Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: card.entry.title,
            style: density.rowTitle(theme, strong: true),
          ),
          TextSpan(
            text: '  $line',
            style: density
                .muted(theme)
                ?.copyWith(
                  color: card.state == AgentState.needsYou ? color : null,
                ),
          ),
        ],
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
    return Semantics(
      button: true,
      label: 'Most urgent: ${card.state.label}, ${card.entry.title}, $line',
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('overview-headline:${card.id}'),
        borderRadius: BorderRadius.circular(Radii.sm),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.sm,
            vertical: Insets.xs + Insets.hair * 2,
          ),
          decoration: BoxDecoration(
            color: card.state == AgentState.needsYou
                ? SurfaceTones.of(context).attentionSurface
                : theme.colorScheme.surfaceContainer,
            borderRadius: BorderRadius.circular(Radii.sm),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: Insets.hair * 2),
                child: glyph,
              ),
              const SizedBox(width: Insets.sm),
              Expanded(child: text),
            ],
          ),
        ),
      ),
    );
  }
}

/// A project with nothing live and nothing today, drawn small.
class OverviewQuietTile extends ConsumerWidget {
  const OverviewQuietTile({
    required this.lane,
    required this.onOpen,
    super.key,
  });

  final OverviewLane lane;
  final ValueChanged<OverviewCard> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final density = UiDensity.of(context);
    final latest = lane.doneOlder.firstOrNull;
    final now = ref.read(clockProvider).nowUtc();
    final said = latest == null
        ? 'nothing yet'
        : 'last active ${compactAge(now.difference(latest.entry.activityAt))} '
              'ago';
    return Material(
      key: ValueKey('overview-quiet-tile:${lane.key}'),
      color: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: latest == null ? null : () => onOpen(latest),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.md,
            vertical: Insets.sm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                lane.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: density.rowTitle(theme),
              ),
              Text(
                said,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: density.muted(theme),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
