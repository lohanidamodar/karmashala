import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/widgets/truncated_text.dart';
import '../../../core/util/clock_provider.dart';
import '../../explorer/application/agent_states.dart';
import '../application/overview_board.dart';
import '../application/overview_providers.dart';
import 'overview_batch_bar.dart';
import 'overview_card_links.dart';
import 'overview_card_parts.dart';
import 'overview_end_button.dart';
import 'overview_resume_actions.dart';
import 'overview_session_parts.dart';
import 'overview_title_block.dart';

/// The edge a card of [state] is drawn with: colour only where the owner is
/// wanted, on the border and never the surface.
Color overviewCardEdge(BuildContext context, AgentState state) {
  final semantic = SemanticColors.of(context);
  return switch (state) {
    AgentState.needsYou => semantic.attention.withValues(
      alpha: SemanticColors.surfaceEdgeAlpha,
    ),
    AgentState.failed => semantic.failure.withValues(
      alpha: SemanticColors.surfaceEdgeAlpha,
    ),
    _ => Theme.of(context).colorScheme.outlineVariant,
  };
}

/// The frame every Overview card shares: one surface, its edge in the state
/// that matters, the keyboard's ring, and a tap that peeks.
class OverviewCardFrame extends ConsumerWidget {
  const OverviewCardFrame({
    required this.card,
    required this.onOpen,
    required this.child,
    super.key,
  });

  final OverviewCard card;
  final ValueChanged<OverviewCard>? onOpen;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final selected = ref.watch(
      overviewFocusProvider.select((f) => f.selected == card.id),
    );
    final radius = BorderRadius.circular(Radii.lg);
    return Material(
      key: ValueKey('overview-card:${card.id}'),
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(
          color: selected
              ? scheme.primary
              : overviewCardEdge(context, card.state),
          width: selected ? StateLayers.focusRingWidth * 2 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: radius,
        onTap: onOpen == null
            ? null
            : () {
                if (!overviewPickSelects(ref, card, touch: _touch(context))) {
                  onOpen!(card);
                }
              },
        onLongPress: () => overviewPickSelects(ref, card, long: true),
        // A right-click opens the card's ⋯ where the pointer is.
        onSecondaryTapUp: (details) => showOverviewCardMenu(
          context,
          ref,
          card,
          at: details.globalPosition,
        ),
        // Hovered or holding the keys, the card shows its End.
        child: OverviewHoverScope(
          child: Padding(
            padding: const EdgeInsets.all(Insets.md),
            child: child,
          ),
        ),
      ),
    );
  }
}

bool _touch(BuildContext context) => UiDensity.of(context).isTouch;

/// [child], [card]'s own widget, with its ties to its parent and its
/// sub-sessions as [among] — the list it is drawn in — has them
/// ([OverviewLinked]): a [phone] says them in words.
Widget overviewTied(
  OverviewCard card,
  List<OverviewCard> among,
  Widget child, {
  bool phone = false,
}) => OverviewLinked(
  key: ValueKey('overview-linked:${card.id}'),
  card: card,
  among: among,
  phone: phone,
  child: child,
);

/// Title, where it runs, and the state chip.
class OverviewCardHeader extends ConsumerWidget {
  const OverviewCardHeader({required this.card, this.chip, super.key});

  final OverviewCard card;

  /// In place of the state chip with its age.
  final Widget? chip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final density = UiDensity.of(context);
    final place = watchOverviewCardPlace(ref, card);
    final agent = watchOverviewAgentName(ref, card);
    final parent = card.breadcrumb;
    final titleStyle = theme.textTheme.bodyMedium?.copyWith(
      fontWeight: FontWeight.w600,
    );
    return Row(
      children: [
        OverviewSelectBox(card: card),
        OverviewAgentRing(
          card: card,
          size: density.isTouch ? Insets.xl + Insets.xs : Chrome.control,
        ),
        const SizedBox(width: Insets.sm),
        Expanded(
          child: OverviewTitleBlock(
            titleFloor: overviewTitleFloor(
              context,
              card.entry.title,
              titleStyle,
            ),
            title: Semantics(
              header: true,
              label: [
                card.entry.title,
                card.state.label,
                ?agent,
                if (place.isNotEmpty) place,
                if (parent != null) 'from $parent',
              ].join(', '),
              excludeSemantics: true,
              // A long press selects the card; hover names it whole.
              child: TruncatedText(
                card.entry.title,
                textKey: ValueKey('overview-card-title:${card.id}'),
                triggerMode: TooltipTriggerMode.manual,
                style: titleStyle,
              ),
            ),
            meta: parent != null || place.isNotEmpty
                ? _ParentChip(
                    // A sub-session's card: a tap peeks its parent.
                    parentId: card.parentId,
                    childId: card.id,
                    child: ExcludeSemantics(
                      child: Text(
                        parent == null
                            ? place
                            // Drawn after its parent, the line names it;
                            // drawn apart from it, it says where it came
                            // from.
                            : card.parentId != null
                            ? '↳ $parent'
                            : '↳ from $parent',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  )
                : null,
            // The menu and End stay their own buttons; the state is in the
            // title's label.
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OverviewNewBadge(card: card),
                const SizedBox(width: Insets.sm),
                Flexible(
                  child: ExcludeSemantics(
                    child: chip ?? OverviewStatePill(card: card),
                  ),
                ),
                OverviewEndButton(card: card),
                OverviewCardMenu(card: card),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// [child], the header's "↳ parent": with a [parentId], a tap peeks it.
class _ParentChip extends ConsumerWidget {
  const _ParentChip({
    required this.parentId,
    required this.childId,
    required this.child,
  });

  final String? parentId;
  final String childId;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final parent = parentId;
    if (parent == null) return child;
    return Semantics(
      button: true,
      label: 'Peek the parent session',
      child: InkWell(
        key: ValueKey('overview-parent-chip:$childId'),
        borderRadius: BorderRadius.circular(Radii.sm),
        onTap: () => ref.read(overviewFocusProvider.notifier).peek(parent),
        child: child,
      ),
    );
  }
}

/// **One session at work**, calm: its state, what it is doing in words, the
/// latest thing it said, its plan step and diff, and its sub-sessions.
class OverviewWorkCard extends ConsumerWidget {
  const OverviewWorkCard({required this.card, required this.onOpen, super.key});

  final OverviewCard card;
  final ValueChanged<OverviewCard> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) => OverviewCardFrame(
    card: card,
    onOpen: onOpen,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        OverviewCardHeader(card: card),
        const SizedBox(height: Insets.sm),
        if (card.waitingOn != null)
          OverviewWaitingOnLine(card: card)
        else
          OverviewActivityLine(card: card),
        const SizedBox(height: Insets.xs),
        OverviewLatestMessage(sessionId: card.id),
        const SizedBox(height: Insets.xs),
        OverviewMetaLine(card: card),
        OverviewUsageLine(sessionId: card.id),
        if (card.children != null) ...[
          const SizedBox(height: Insets.xs),
          OverviewSubSessions(card: card, onOpen: onOpen),
        ],
      ],
    ),
  );
}

/// One session that ended today, as a line.
class OverviewDoneRow extends ConsumerWidget {
  const OverviewDoneRow({required this.card, required this.onOpen, super.key});

  final OverviewCard card;
  final ValueChanged<OverviewCard> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final now = ref.read(clockProvider).nowUtc();
    final place = watchOverviewCardPlace(ref, card);
    final row = InkWell(
      key: ValueKey('overview-done:${card.id}'),
      borderRadius: BorderRadius.circular(Radii.sm),
      onTap: () => onOpen(card),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.xs,
          vertical: Insets.xs,
        ),
        child: Row(
          children: [
            OverviewAgentRing(card: card, size: Insets.xl - Insets.xxs),
            const SizedBox(width: Insets.sm),
            Expanded(
              child: OverviewTitleBlock(
                titleFloor: overviewTitleFloor(
                  context,
                  card.entry.title,
                  theme.textTheme.bodySmall,
                ),
                title: TruncatedText.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: card.entry.title),
                      if (place.isNotEmpty)
                        TextSpan(
                          text: '  $place',
                          style: TextStyle(color: muted),
                        ),
                    ],
                  ),
                  textKey: ValueKey('overview-card-title:${card.id}'),
                  style: theme.textTheme.bodySmall,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      compactAge(now.difference(card.entry.activityAt)),
                      style: theme.textTheme.labelSmall?.copyWith(color: muted),
                    ),
                    OverviewEndButton(card: card),
                    OverviewCardMenu(card: card),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
    final children = card.children;
    if (children == null) return OverviewHoverScope(child: row);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        OverviewHoverScope(child: row),
        _DoneRowSubSessions(card: card, total: children.total, onOpen: onOpen),
      ],
    );
  }
}

/// "↳ 2 sub-sessions" under a done row, opening in place to the rows a
/// working card shows: a done session's children seen without the peek.
class _DoneRowSubSessions extends StatefulWidget {
  const _DoneRowSubSessions({
    required this.card,
    required this.total,
    required this.onOpen,
  });

  final OverviewCard card;
  final int total;
  final ValueChanged<OverviewCard> onOpen;

  @override
  State<_DoneRowSubSessions> createState() => _DoneRowSubSessionsState();
}

class _DoneRowSubSessionsState extends State<_DoneRowSubSessions> {
  var _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final n = widget.total;
    return Padding(
      padding: const EdgeInsets.only(left: Insets.xl + Insets.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            key: ValueKey('overview-done-subs:${widget.card.id}'),
            borderRadius: BorderRadius.circular(Radii.sm),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Insets.xxs),
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      '↳ $n ${n == 1 ? 'sub-session' : 'sub-sessions'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Icon(
                    _open ? AppIcons.caretUp : AppIcons.caretDown,
                    size: UiDensity.of(context).iconSmall,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (_open)
            OverviewSubSessions(card: widget.card, onOpen: widget.onOpen),
        ],
      ),
    );
  }
}
