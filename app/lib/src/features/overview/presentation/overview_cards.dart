import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/util/clock_provider.dart';
import '../../explorer/application/agent_states.dart';
import '../application/overview_board.dart';
import '../application/overview_providers.dart';
import 'overview_batch_bar.dart';
import 'overview_card_parts.dart';
import 'overview_end_button.dart';
import 'overview_resume_actions.dart';
import 'overview_session_parts.dart';

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

/// [child], [card]'s own widget, tied to its parent's when the parent is in
/// [among] — drawn just before it: indented, with a thin line down its side.
/// Anything else is [child] as it is.
Widget overviewTied(OverviewCard card, List<OverviewCard> among, Widget child) {
  final parent = card.parentId;
  if (parent == null || !among.any((c) => c.id == parent)) return child;
  return OverviewChildLink(card: card, child: child);
}

/// A sub-session drawn as a card of its own, tied to its parent's just
/// before it.
class OverviewChildLink extends StatelessWidget {
  const OverviewChildLink({required this.card, required this.child, super.key});

  final OverviewCard card;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    key: ValueKey('overview-child-link:${card.id}'),
    margin: const EdgeInsets.only(left: Insets.sm),
    padding: const EdgeInsets.only(left: Insets.sm),
    decoration: BoxDecoration(
      border: Border(
        left: BorderSide(
          color: Theme.of(context).colorScheme.outlineVariant,
          width: StateLayers.focusRingWidth,
        ),
      ),
    ),
    child: child,
  );
}

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
    final header = Semantics(
      header: true,
      label: [
        card.entry.title,
        card.state.label,
        ?agent,
        if (place.isNotEmpty) place,
        if (parent != null) 'from $parent',
      ].join(', '),
      excludeSemantics: true,
      child: Row(
        children: [
          OverviewSelectBox(card: card),
          OverviewAgentRing(
            card: card,
            size: density.isTouch ? Insets.xl + Insets.xs : Chrome.control,
          ),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  card.entry.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (parent != null || place.isNotEmpty)
                  Text(
                    parent == null
                        ? place
                        // Drawn after its parent, the line names it; drawn
                        // apart from it, it says where it came from.
                        : card.parentId != null
                        ? '↳ $parent'
                        : '↳ from $parent',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          OverviewNewBadge(card: card),
          const SizedBox(width: Insets.sm),
          chip ?? OverviewStatePill(card: card),
        ],
      ),
    );
    // Outside the header's one label, so the menu stays its own button.
    return Row(
      children: [
        Expanded(child: header),
        OverviewEndButton(card: card),
        OverviewCardMenu(card: card),
      ],
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
              child: Text.rich(
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
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
            Text(
              compactAge(now.difference(card.entry.activityAt)),
              style: theme.textTheme.labelSmall?.copyWith(color: muted),
            ),
            OverviewEndButton(card: card),
            OverviewCardMenu(card: card),
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
