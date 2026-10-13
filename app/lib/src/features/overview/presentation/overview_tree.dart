import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/widgets/truncated_text.dart';
import '../../sessions/application/session_status_providers.dart';
import '../../sessions/presentation/approval_request_card.dart';
import '../application/overview_batch.dart';
import '../application/overview_board.dart';
import '../application/overview_links.dart';
import '../application/overview_providers.dart';
import '../application/overview_reads.dart';
import '../application/overview_tree.dart';
import 'overview_batch_bar.dart';
import 'overview_card_links.dart';
import 'overview_card_parts.dart';
import 'overview_cards.dart';
import 'overview_done_card.dart';
import 'overview_end_button.dart';
import 'overview_queue_card.dart' show overviewAskKind, OverviewAskKind;
import 'overview_queue_card.dart' show overviewMachineAndBranch;
import 'overview_resume_actions.dart';
import 'overview_session_parts.dart';
import 'session_avatar.dart';

/// **A family on the dashboard, as a tree**: the root's avatar with its card
/// attached, and a stem down from it with each sub-session branching off on
/// a rounded elbow — an avatar and a pill, opening inline below when clicked.
/// A sub-session's own sub-sessions branch off it the same way. The root
/// card is a working card, or a done one when [ready]; [compact] draws the
/// phone's smaller avatars.
class OverviewFamilyTree extends ConsumerStatefulWidget {
  const OverviewFamilyTree({
    required this.node,
    required this.onOpen,
    this.ready = false,
    this.compact = false,
    super.key,
  });

  final OverviewTreeNode node;
  final ValueChanged<OverviewCard> onOpen;
  final bool ready;
  final bool compact;

  @override
  ConsumerState<OverviewFamilyTree> createState() => _OverviewFamilyTreeState();
}

class _OverviewFamilyTreeState extends ConsumerState<OverviewFamilyTree> {
  /// The sub-sessions opened inline.
  final _open = <String>{};

  double get _rootSize =>
      widget.compact ? Chrome.sessionAvatarCompact : Chrome.sessionAvatar;
  double get _kidSize =>
      widget.compact ? Chrome.subSessionAvatarCompact : Chrome.subSessionAvatar;

  /// From a stem to the avatar an elbow reaches.
  double get _elbow =>
      widget.compact ? Insets.lg + Insets.xs : Insets.xl + Insets.xs;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final root = widget.node.card;
    final folded = ref.watch(
      overviewFoldedParentsProvider.select((s) => s.contains(root.id)),
    );
    final line = sessionRingColor(
      context,
      root.state,
    ).withValues(alpha: SemanticColors.surfaceEdgeAlpha);
    final surface = scheme.surfaceContainerLowest;
    final pad = widget.compact ? Insets.md : Insets.lg;
    return Semantics(
      container: true,
      label: widget.node.children.isEmpty
          ? root.entry.title
          : '${root.entry.title} and its sub-sessions',
      child: Container(
        key: ValueKey('overview-family:${root.id}'),
        padding: EdgeInsets.all(pad),
        decoration: BoxDecoration(
          color: surface,
          borderRadius: BorderRadius.circular(Radii.lg),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            OverviewParentLink(card: root),
            _subtree(
              widget.node,
              root: true,
              folded: folded,
              line: line,
              surface: surface,
            ),
          ],
        ),
      ),
    );
  }

  Widget _subtree(
    OverviewTreeNode node, {
    required bool root,
    required bool folded,
    required Color line,
    required Color surface,
  }) {
    final size = root ? _rootSize : _kidSize;
    final kids = root && folded ? const <OverviewTreeNode>[] : node.children;
    final id = node.card.id;
    final head = root
        ? _rootHead(node, surface)
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _TreePill(
                key: ValueKey('overview-tree-node:$id'),
                node: node,
                size: size,
                open: _open.contains(id),
                line: line,
                halo: surface,
                onToggle: () => setState(
                  () => _open.contains(id) ? _open.remove(id) : _open.add(id),
                ),
                onOpenChat: () => widget.onOpen(node.card),
              ),
              if (_open.contains(id))
                _TreeDetail(
                  card: node.card,
                  tuck: size / 2,
                  line: line,
                  onOpen: widget.onOpen,
                ),
            ],
          );
    if (kids.isEmpty) return head;
    final stemAt = size / 2 - Chrome.treeLine / 2;
    final elbowAt = Insets.md + _kidSize / 2;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        CustomPaint(
          painter: _StemPainter(x: size / 2, from: size, color: line),
          child: head,
        ),
        Padding(
          padding: EdgeInsets.only(left: stemAt),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (i, kid) in kids.indexed)
                CustomPaint(
                  key: ValueKey('overview-tree-branch:${kid.card.id}'),
                  painter: _ElbowPainter(
                    last: i == kids.length - 1,
                    elbowAt: elbowAt,
                    reach: _elbow,
                    color: line,
                  ),
                  child: Padding(
                    padding: EdgeInsets.only(top: Insets.md, left: _elbow),
                    child: _subtree(
                      kid,
                      root: false,
                      folded: false,
                      line: line,
                      surface: surface,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// The root's avatar with its card attached, tucked behind it.
  Widget _rootHead(OverviewTreeNode node, Color surface) {
    final card = node.card;
    final size = _rootSize;
    final tuck = size / 2;
    final below = node.descendants.toList();
    final footer = below.isEmpty
        ? null
        : OverviewFamilyFooter(root: card, below: below);
    final Widget body = widget.ready
        ? OverviewDoneCard(
            key: ValueKey('overview-ready-card:${card.id}'),
            card: card,
            onOpen: widget.onOpen,
            leading: tuck,
            footer: footer,
            family: below,
          )
        : OverviewWorkCard(
            key: ValueKey('overview-work-card:${card.id}'),
            card: card,
            onOpen: widget.onOpen,
            leading: tuck,
            footer: footer,
          );
    return Stack(
      children: [
        Padding(
          padding: EdgeInsets.only(left: tuck),
          child: OverviewFamilyHover(card: card, child: body),
        ),
        Positioned(
          left: 0,
          top: 0,
          child: IgnorePointer(
            child: SessionAvatar(
              card: card,
              size: size,
              progress: overviewDoneShare(node),
              waiting: overviewWaitingIn(node),
              halo: surface,
            ),
          ),
        ),
      ],
    );
  }
}

/// "4 of 5 done · 1 working" and the fold under a family's root card:
/// folded, only the root stays, saying how many are away.
class OverviewFamilyFooter extends ConsumerWidget {
  const OverviewFamilyFooter({
    required this.root,
    required this.below,
    super.key,
  });

  final OverviewCard root;
  final List<OverviewCard> below;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final folded = ref.watch(
      overviewFoldedParentsProvider.select((s) => s.contains(root.id)),
    );
    final n = below.length;
    final count = '$n ${n == 1 ? 'sub-session' : 'sub-sessions'}';
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: Insets.sm,
      children: [
        Text(
          overviewFamilySummary(below),
          key: ValueKey('overview-family-summary:${root.id}'),
          style: theme.textTheme.labelSmall?.copyWith(color: muted),
        ),
        Semantics(
          button: true,
          expanded: !folded,
          label: folded ? 'Show $count' : 'Fold $count',
          excludeSemantics: true,
          child: InkWell(
            key: ValueKey('overview-children-fold:${root.id}'),
            onTap: () => ref
                .read(overviewFoldedParentsProvider.notifier)
                .toggle(root.id),
            borderRadius: BorderRadius.circular(Radii.sm),
            child: TouchTarget(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Insets.xs,
                  vertical: Insets.xxs,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      folded ? AppIcons.caretRight : AppIcons.caretDown,
                      size: UiDensity.of(context).iconSmall,
                      color: muted,
                    ),
                    const SizedBox(width: Insets.xs),
                    Flexible(
                      child: Text(
                        count,
                        key: ValueKey('overview-children-line:${root.id}'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: muted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// **A sub-session on the tree**: its avatar and a pill with its title, its
/// state and age, and its latest line. A pointer over it slides the pill,
/// lights the avatar's ring, puts the pick box on the avatar's face and
/// Open chat over the state; a click, Enter or Space opens it
/// below. Nothing in it changes size.
class _TreePill extends ConsumerStatefulWidget {
  const _TreePill({
    required this.node,
    required this.size,
    required this.open,
    required this.line,
    required this.halo,
    required this.onToggle,
    required this.onOpenChat,
    super.key,
  });

  final OverviewTreeNode node;
  final double size;
  final bool open;
  final Color line;
  final Color halo;
  final VoidCallback onToggle;
  final VoidCallback onOpenChat;

  @override
  ConsumerState<_TreePill> createState() => _TreePillState();
}

class _TreePillState extends ConsumerState<_TreePill> {
  var _hovered = false;
  var _pressed = false;
  var _focused = false;

  /// The keys are on the pill, its pick box or its hover actions.
  var _within = false;

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final card = node.card;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final motion = Motion.of(context);
    final density = UiDensity.of(context);
    final touch = density.isTouch;
    // Hover is a pointer's: a thumb never rests on a pill.
    final hovered = _hovered && !touch;
    final active = (_hovered || _within) && !touch;
    final selected = ref.watch(
      overviewFocusProvider.select((f) => f.selected == card.id),
    );
    final selecting = ref.watch(
      overviewSelectionProvider.select((s) => !s.isEmpty),
    );
    final picked = ref.watch(
      overviewSelectionProvider.select((s) => s.contains(card.id)),
    );
    final size = widget.size;
    final tuck = size / 2;
    final edge = _focused || selected
        ? scheme.primary
        : widget.open
        ? widget.line
        : hovered
        ? scheme.outline
        : scheme.outlineVariant;
    const round = Radius.circular(Radii.lg);
    const flat = Radius.circular(Radii.sm);
    final minHeight = touch && Touch.target > size ? Touch.target : size;

    final pill = Material(
      color: hovered ? scheme.surfaceContainer : scheme.surfaceContainerLow,
      elevation: hovered ? Elevations.popup : 0,
      shadowColor: scheme.shadow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.only(
          topLeft: round,
          topRight: round,
          bottomLeft: widget.open ? flat : round,
          bottomRight: widget.open ? flat : round,
        ),
        side: BorderSide(
          color: edge,
          width: _focused || selected ? StateLayers.focusRingWidth * 2 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Shortcuts(
        // The pill's own: the board's Enter means "send" elsewhere.
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        child: InkWell(
          key: ValueKey('overview-tree-pill:${card.id}'),
          onTap: () {
            if (!overviewPickSelects(ref, card, touch: touch)) {
              widget.onToggle();
            }
          },
          onLongPress: () => overviewPickSelects(ref, card, long: true),
          onSecondaryTapUp: (details) => showOverviewCardMenu(
            context,
            ref,
            card,
            at: details.globalPosition,
          ),
          onHighlightChanged: (on) => setState(() => _pressed = on),
          onFocusChange: (on) => setState(() => _focused = on),
          child: OverviewHoverScope(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: minHeight),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  tuck + Insets.sm,
                  Insets.xs,
                  Insets.sm,
                  Insets.xs,
                ),
                child: LayoutBuilder(
                  builder: (context, box) {
                    // Narrow, the state takes a line of its own so the
                    // title keeps its words.
                    final narrow =
                        box.maxWidth <
                        WidthClass.scaleBreakpoint(
                          Chrome.familyCellMin / 2,
                          MediaQuery.textScalerOf(context),
                        );
                    final along = narrow
                        ? AlignmentDirectional.centerStart
                        : AlignmentDirectional.centerEnd;
                    final chip = Align(
                      alignment: along,
                      child: touch
                          ? OverviewStatePill(card: card)
                          : _HoverTail(
                              card: card,
                              active: active,
                              alignment: along,
                              onOpenChat: widget.onOpenChat,
                            ),
                    );
                    return Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              flex: 3,
                              // A long press picks the pill; hover names a
                              // cut title whole.
                              child: TruncatedText(
                                card.entry.title,
                                textKey: ValueKey(
                                  'overview-card-title:${card.id}',
                                ),
                                triggerMode: TooltipTriggerMode.manual,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurface,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            const SizedBox(width: Insets.xs),
                            OverviewNewBadge(card: card),
                            if (!narrow) ...[
                              const SizedBox(width: Insets.xs),
                              Flexible(flex: 2, child: chip),
                            ],
                          ],
                        ),
                        if (narrow) chip,
                        _LatestLine(card: card),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );

    // Gmail's way: the box takes the avatar's face, inside its bounds.
    final pickable = selecting || active;
    return Semantics(
      expanded: widget.open,
      child: OverviewFamilyHover(
        card: card,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onFocusChange: (on) => setState(() => _within = on),
            child: Stack(
              children: [
                Padding(
                  padding: EdgeInsets.only(left: tuck),
                  child: AnimatedContainer(
                    duration: motion.fast,
                    curve: Motion.standard,
                    transform: Matrix4.translationValues(
                      hovered ? Insets.tight : 0,
                      0,
                      0,
                    ),
                    child: AnimatedScale(
                      scale: _pressed ? Motion.pressScale : 1,
                      duration: motion.fast,
                      child: pill,
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  top: 0,
                  width: size,
                  height: size,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      IgnorePointer(
                        child: SessionAvatar(
                          card: card,
                          size: size,
                          progress: overviewDoneShare(node),
                          waiting: overviewWaitingIn(node),
                          halo: widget.halo,
                          glow: hovered,
                        ),
                      ),
                      if (pickable)
                        Container(
                          width: SessionAvatar.faceOf(size),
                          height: SessionAvatar.faceOf(size),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: scheme.surfaceContainerHigh,
                          ),
                          child: Checkbox(
                            key: ValueKey('overview-tree-select:${card.id}'),
                            value: picked,
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            semanticLabel: 'Select ${card.entry.title}',
                            onChanged: (_) => ref
                                .read(overviewSelectionProvider.notifier)
                                .toggle(card.id),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A pill's tail: its state, with its hover actions laid over it while
/// [active]. Always the size of both, so a hover moves nothing.
class _HoverTail extends StatelessWidget {
  const _HoverTail({
    required this.card,
    required this.active,
    required this.alignment,
    required this.onOpenChat,
  });

  final OverviewCard card;
  final bool active;
  final AlignmentGeometry alignment;
  final VoidCallback onOpenChat;

  @override
  Widget build(BuildContext context) {
    final motion = Motion.of(context);
    final density = UiDensity.of(context);
    Widget action(String key, String tip, IconData icon, VoidCallback? on) =>
        IconButton(
          key: ValueKey('$key:${card.id}'),
          tooltip: tip,
          onPressed: on,
          padding: EdgeInsets.zero,
          iconSize: density.iconSmall,
          constraints: const BoxConstraints.tightFor(
            width: Chrome.control,
            height: Chrome.control,
          ),
          icon: Icon(icon),
        );
    return Stack(
      alignment: alignment,
      children: [
        AnimatedOpacity(
          opacity: active ? 0 : 1,
          duration: motion.fast,
          child: ExcludeSemantics(
            excluding: active,
            child: OverviewStatePill(card: card),
          ),
        ),
        Visibility(
          visible: active,
          maintainSize: true,
          maintainAnimation: true,
          maintainState: true,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              action(
                'overview-tree-chat',
                'Open chat',
                AppIcons.arrowSquareOut,
                onOpenChat,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The latest thing a sub-session said, on one line; what it is doing while
/// it has said nothing yet.
class _LatestLine extends ConsumerWidget {
  const _LatestLine({required this.card});

  final OverviewCard card;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final said = ref.watch(overviewLastAnswerProvider(card.id)).value?.text;
    if (said != null) {
      return OverviewLatestMessage(sessionId: card.id, maxLines: 1);
    }
    final theme = Theme.of(context);
    return Text(
      watchOverviewLine(ref, card),
      key: ValueKey('overview-tree-line:${card.id}'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// A sub-session opened on the tree: all it last said, its step and diff, a
/// waiting question answered in place, and its actions — Archive, Hand back,
/// Open chat, End and the session menu.
class _TreeDetail extends ConsumerWidget {
  const _TreeDetail({
    required this.card,
    required this.tuck,
    required this.line,
    required this.onOpen,
  });

  final OverviewCard card;
  final double tuck;
  final Color line;
  final ValueChanged<OverviewCard> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final report = ref.watch(agentSessionStatusProvider(card.id)).asData?.value;
    final asks =
        card.column == BoardColumn.needsYou &&
        !card.heldBySubSessions &&
        overviewAskKind(card, report) == OverviewAskKind.inPlace;
    return Padding(
      padding: EdgeInsets.only(left: tuck + Insets.sm),
      child: Container(
        key: ValueKey('overview-tree-detail:${card.id}'),
        padding: const EdgeInsets.all(Insets.md),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          border: Border.all(color: line),
          borderRadius: const BorderRadius.vertical(
            bottom: Radius.circular(Radii.lg),
          ),
        ),
        child: OverviewHoverScope(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              OverviewLatestMessage(sessionId: card.id, maxLines: 6),
              const SizedBox(height: Insets.xs),
              OverviewMetaLine(card: card),
              if (asks) ...[
                const SizedBox(height: Insets.sm),
                ApprovalRequestCard(
                  sessionId: card.id,
                  board: true,
                  where: overviewMachineAndBranch(ref, card),
                ),
              ],
              const SizedBox(height: Insets.sm),
              OverviewCloseActions(
                card: card,
                merge: false,
                extra: [
                  FilledButton.tonal(
                    key: ValueKey('overview-tree-open:${card.id}'),
                    onPressed: () => onOpen(card),
                    child: const Text('Open chat'),
                  ),
                  OverviewEndButton(card: card),
                  OverviewCardMenu(card: card),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The stem down from an avatar's foot, under the node it belongs to.
class _StemPainter extends CustomPainter {
  _StemPainter({required this.x, required this.from, required this.color});

  final double x;
  final double from;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.height <= from) return;
    canvas.drawLine(Offset(x, from), Offset(x, size.height), _line(color));
  }

  @override
  bool shouldRepaint(_StemPainter old) =>
      old.x != x || old.from != from || old.color != color;
}

/// One branch: the stem carried down to the avatar's middle, where it turns
/// on a rounded elbow to meet it — and on past it, unless it is the [last].
class _ElbowPainter extends CustomPainter {
  _ElbowPainter({
    required this.last,
    required this.elbowAt,
    required this.reach,
    required this.color,
  });

  final bool last;
  final double elbowAt;
  final double reach;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = _line(color);
    const x = Chrome.treeLine / 2;
    final radius = Radii.lg.clamp(0, elbowAt).toDouble();
    canvas.drawPath(
      Path()
        ..moveTo(x, 0)
        ..lineTo(x, elbowAt - radius)
        ..arcToPoint(
          Offset(x + radius, elbowAt),
          radius: Radius.circular(radius),
          clockwise: false,
        )
        ..lineTo(reach + Insets.xs, elbowAt),
      paint,
    );
    if (!last) {
      canvas.drawLine(const Offset(x, 0), Offset(x, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(_ElbowPainter old) =>
      old.last != last ||
      old.elbowAt != elbowAt ||
      old.reach != reach ||
      old.color != color;
}

Paint _line(Color color) => Paint()
  ..color = color
  ..style = PaintingStyle.stroke
  ..strokeWidth = Chrome.treeLine
  ..strokeCap = StrokeCap.round;
