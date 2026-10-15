import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/widgets/truncated_text.dart';
import '../../../core/util/clock_provider.dart';
import '../../sessions/application/session_status_providers.dart';
import '../../sessions/presentation/approval_request_card.dart';
import '../application/overview_batch.dart';
import '../application/overview_board.dart';
import '../application/overview_links.dart';
import '../application/overview_providers.dart';
import '../application/overview_quick_message.dart';
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
import 'overview_quick_composer.dart';
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

  /// The one sub-session with a composer under its pill, from its hover.
  String? _composing;

  /// What became of the last message sent from under a pill, until it
  /// answers.
  final _sent = <String, _Awaiting>{};

  /// The root's composer, kept as its card turns from working to done.
  final _rootComposer = GlobalKey();

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
    final folded = ref.watch(overviewFoldedParentsProvider);
    final line = sessionRingColor(
      context,
      root.state,
    ).withValues(alpha: SemanticColors.surfaceEdgeAlpha);
    // On a phone, one frame: a session alone is its card, unframed; a
    // family keeps its frame, and its root card draws none of its own.
    final framed = !widget.compact || widget.node.children.isNotEmpty;
    final surface = framed
        ? scheme.surfaceContainerLowest
        : Theme.of(context).scaffoldBackgroundColor;
    final pad = widget.compact ? Insets.sm : Insets.lg;
    return Semantics(
      container: true,
      label: widget.node.children.isEmpty
          ? root.entry.title
          : '${root.entry.title} and its sub-sessions',
      child: Container(
        key: ValueKey('overview-family:${root.id}'),
        padding: framed ? EdgeInsets.all(pad) : null,
        decoration: framed
            ? BoxDecoration(
                color: surface,
                borderRadius: BorderRadius.circular(Radii.lg),
                border: Border.all(color: scheme.outlineVariant),
              )
            : null,
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
    required Set<String> folded,
    required Color line,
    required Color surface,
    OverviewCard? parent,
    int depth = 0,
  }) {
    final size = root ? _rootSize : _kidSize;
    final id = node.card.id;
    final below = node.descendants.toList();
    final shut = below.isNotEmpty && folded.contains(id);
    Widget head = root
        ? _rootHead(node, surface)
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _TreePill(
                key: ValueKey('overview-tree-node:$id'),
                node: node,
                parent: parent,
                size: size,
                open: _open.contains(id),
                line: line,
                halo: surface,
                hidden: shut ? below : null,
                sent: _sent[id],
                onSentSeen: () => setState(() => _sent.remove(id)),
                onToggle: () => setState(() {
                  if (!_open.remove(id)) _open.add(id);
                  if (_composing == id) _composing = null;
                }),
                onOpenChat: () => widget.onOpen(node.card),
                onMessage: () => setState(() {
                  _composing = _composing == id ? null : id;
                  _open.remove(id);
                  _sent.remove(id);
                }),
              ),
              if (_composing == id)
                _TreeComposer(
                  card: node.card,
                  tuck: size / 2,
                  line: line,
                  onClose: () => setState(() => _composing = null),
                  onSent: (sent) {
                    final read = ref.read(overviewLastAnswerProvider(id));
                    final now = ref.read(clockProvider).nowUtc();
                    setState(() {
                      _composing = null;
                      _sent[id] = _Awaiting(
                        sent,
                        at: now,
                        before: read.isLoading || read.hasError
                            ? null
                            : read.value,
                      );
                    });
                  },
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
    if (below.isNotEmpty) {
      head = _withKnob(
        head,
        id: id,
        size: size,
        count: below.length,
        shut: shut,
      );
    }
    // A fold hides what is below; a family's root keeps a strip saying what.
    final branches = <(Key?, Widget)>[
      if (!shut)
        for (final kid in node.children)
          (
            ValueKey('overview-tree-branch:${kid.card.id}'),
            _subtree(
              kid,
              root: false,
              folded: folded,
              line: line,
              surface: surface,
              parent: node.card,
              depth: depth + 1,
            ),
          )
      else if (root)
        (null, _FoldedStrip(rootId: id, below: below, height: _kidSize)),
    ];
    final stemAt = size / 2 - Chrome.treeLine / 2;
    final elbowAt = Insets.md + _kidSize / 2;
    // Past the deepest step in, a sub-session hangs straight under its parent.
    final flat = depth >= Chrome.treeIndentDepth;
    // The head keeps one ancestry folded or not, or its composers' state goes.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        CustomPaint(
          painter: branches.isEmpty
              ? null
              : _StemPainter(x: size / 2, from: size, color: line),
          child: head,
        ),
        if (branches.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(left: flat ? 0 : stemAt),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (i, (key, branch)) in branches.indexed)
                  CustomPaint(
                    key: key,
                    painter: flat
                        ? _RunPainter(
                            x: size / 2,
                            last: i == branches.length - 1,
                            to: Insets.md,
                            color: line,
                          )
                        : _ElbowPainter(
                            last: i == branches.length - 1,
                            elbowAt: elbowAt,
                            reach: _elbow,
                            color: line,
                          ),
                    child: Padding(
                      padding: EdgeInsets.only(
                        top: Insets.md,
                        left: flat ? 0 : _elbow,
                      ),
                      child: branch,
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  /// [head] with the fold knob on its stem, just under its avatar.
  Widget _withKnob(
    Widget head, {
    required String id,
    required double size,
    required int count,
    required bool shut,
  }) {
    final touch = UiDensity.of(context).isTouch;
    final face = touch ? Chrome.treeKnobTouch : Chrome.treeKnob;
    final box = touch ? Touch.target : face;
    final centre = size + Insets.xxs + face / 2;
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: centre + box / 2),
      child: Stack(
        clipBehavior: Clip.none,
        fit: StackFit.passthrough,
        children: [
          head,
          Positioned(
            left: size / 2 - box / 2,
            top: centre - box / 2,
            width: box,
            height: box,
            child: _FoldKnob(id: id, count: count, shut: shut, face: face),
          ),
        ],
      ),
    );
  }

  /// The root's avatar with its card attached, tucked behind it.
  Widget _rootHead(OverviewTreeNode node, Color surface) {
    final card = node.card;
    final size = _rootSize;
    final tuck = size / 2;
    final below = node.descendants.toList();
    final bare = widget.compact && node.children.isNotEmpty;
    // The parent always takes a message of its own, a family or not.
    final footer = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (below.isNotEmpty) ...[
          OverviewFamilyFooter(root: card, below: below),
          const SizedBox(height: Insets.xs),
        ],
        OverviewQuickComposer(key: _rootComposer, card: card),
      ],
    );
    final Widget body = widget.ready
        ? OverviewDoneCard(
            key: ValueKey('overview-ready-card:${card.id}'),
            card: card,
            onOpen: widget.onOpen,
            leading: tuck,
            footer: footer,
            family: below,
            compact: widget.compact,
            bare: bare,
          )
        : OverviewWorkCard(
            key: ValueKey('overview-work-card:${card.id}'),
            card: card,
            onOpen: widget.onOpen,
            leading: tuck,
            footer: footer,
            compact: widget.compact,
            bare: bare,
          );
    return _RootHead(
      node: node,
      size: size,
      halo: surface,
      child: Padding(
        padding: EdgeInsets.only(left: tuck),
        child: OverviewFamilyHover(card: card, child: body),
      ),
    );
  }
}

/// A family root's avatar over its card's edge, the pick box on the
/// avatar's face as a pill's is: while picking, or under a pointer over it.
class _RootHead extends ConsumerStatefulWidget {
  const _RootHead({
    required this.node,
    required this.size,
    required this.halo,
    required this.child,
  });

  final OverviewTreeNode node;
  final double size;
  final Color halo;

  /// The card, tucked behind the avatar.
  final Widget child;

  @override
  ConsumerState<_RootHead> createState() => _RootHeadState();
}

class _RootHeadState extends ConsumerState<_RootHead> {
  var _hovered = false;
  var _within = false;

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final card = node.card;
    final size = widget.size;
    final touch = UiDensity.of(context).isTouch;
    final selecting = ref.watch(
      overviewSelectionProvider.select((s) => !s.isEmpty),
    );
    final pickable = selecting || ((_hovered || _within) && !touch);
    final hit = touch && Touch.target > size ? Touch.target : size;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (on) => setState(() => _within = on),
        child: Stack(
          children: [
            widget.child,
            Positioned(
              left: 0,
              top: 0,
              child: IgnorePointer(
                child: SessionAvatar(
                  card: card,
                  size: size,
                  progress: overviewDoneShare(node),
                  waiting: overviewWaitingIn(node),
                  halo: widget.halo,
                ),
              ),
            ),
            if (pickable)
              Positioned(
                left: 0,
                top: 0,
                width: hit,
                height: hit,
                child: _AvatarPickBox(card: card, size: size),
              ),
          ],
        ),
      ),
    );
  }
}

/// Gmail's way: the pick box on an avatar's face, inside its bounds, in a
/// hit area from its corner.
class _AvatarPickBox extends ConsumerWidget {
  const _AvatarPickBox({required this.card, required this.size});

  final OverviewCard card;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final picked = ref.watch(
      overviewSelectionProvider.select((s) => s.contains(card.id)),
    );
    void toggle() =>
        ref.read(overviewSelectionProvider.notifier).toggle(card.id);
    return GestureDetector(
      key: ValueKey('overview-tree-select-hit:${card.id}'),
      behavior: HitTestBehavior.opaque,
      excludeFromSemantics: true,
      onTap: toggle,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox.square(
          dimension: size,
          child: Center(
            child: Container(
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
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                semanticLabel: 'Select ${card.entry.title}',
                onChanged: (_) => toggle(),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A message sent from under a pill, and the answer read when it went.
class _Awaiting {
  _Awaiting(this.sent, {required this.at, this.before});

  final QuickMessageSent sent;
  final DateTime at;

  /// Null while no read had settled; the first one since is taken instead.
  LastAnswer? before;
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
    final count = overviewSubSessionCount(below.length);
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
/// Message and Open chat over the state; a click, Enter or Space opens it
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
    required this.onMessage,
    required this.onSentSeen,
    this.parent,
    this.hidden,
    this.sent,
    super.key,
  });

  final OverviewTreeNode node;

  /// The session it branches off: where it runs is said only where that
  /// differs.
  final OverviewCard? parent;
  final double size;
  final bool open;
  final Color line;
  final Color halo;
  final VoidCallback onToggle;
  final VoidCallback onOpenChat;

  /// The hover's Message: a composer under the pill.
  final VoidCallback onMessage;

  /// What its fold hides, said in place of its latest line.
  final List<OverviewCard>? hidden;

  /// A message sent from under the pill, said in place of its latest line
  /// until the session answers; then [onSentSeen].
  final _Awaiting? sent;
  final VoidCallback onSentSeen;

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
    if (widget.sent case final awaiting?) {
      ref.listen(overviewLastAnswerProvider(card.id), (_, now) {
        if (now.isLoading || now.hasError || !now.hasValue) return;
        final said = now.requireValue;
        if (said.answers(sentAt: awaiting.at, before: awaiting.before)) {
          widget.onSentSeen();
        } else {
          // The first read since it went, when none had been read before.
          awaiting.before ??= said;
        }
      });
    }
    final size = widget.size;
    final tuck = size / 2;
    final apart = widget.parent == null
        ? ''
        : watchOverviewPlaceApart(ref, card, widget.parent!);
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
                              onMessage: widget.onMessage,
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
                            if (apart.isNotEmpty) ...[
                              const SizedBox(width: Insets.xs),
                              Flexible(
                                flex: 2,
                                child: Tooltip(
                                  message: 'Runs in $apart',
                                  child: Text(
                                    apart,
                                    key: ValueKey(
                                      'overview-tree-place:${card.id}',
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(width: Insets.xs),
                            OverviewNewBadge(card: card),
                            if (!narrow) ...[
                              const SizedBox(width: Insets.xs),
                              Flexible(flex: 2, child: chip),
                            ],
                          ],
                        ),
                        if (narrow) chip,
                        if (widget.hidden case final hidden?)
                          Row(
                            children: [
                              _AvatarStack(
                                cards: hidden,
                                size: Chrome.miniAvatar,
                              ),
                              const SizedBox(width: Insets.xs),
                              Expanded(
                                child: Text(
                                  overviewFoldedLine(hidden),
                                  key: ValueKey(
                                    'overview-tree-folded-line:${card.id}',
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          )
                        else if (widget.sent case final sent?)
                          OverviewSentStatus(
                            key: ValueKey('overview-tree-sent:${card.id}'),
                            sessionId: card.id,
                            sent: sent.sent,
                          )
                        else
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
                  child: IgnorePointer(
                    child: SessionAvatar(
                      card: card,
                      size: size,
                      progress: overviewDoneShare(node),
                      waiting: overviewWaitingIn(node),
                      halo: widget.halo,
                      glow: hovered,
                    ),
                  ),
                ),
                if (pickable)
                  // A thumb's target from the avatar's corner, inside the
                  // pill's bounds; the knob, drawn later, keeps its own.
                  Positioned(
                    left: 0,
                    top: 0,
                    width: minHeight,
                    height: minHeight,
                    child: _AvatarPickBox(card: card, size: size),
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
    required this.onMessage,
    required this.onOpenChat,
  });

  final OverviewCard card;
  final bool active;
  final AlignmentGeometry alignment;
  final VoidCallback onMessage;
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
                'overview-tree-message',
                'Message',
                AppIcons.chatCircle,
                onMessage,
              ),
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

/// The round fold on a stem under an avatar: how many it hides while
/// folded, a minus while open.
class _FoldKnob extends ConsumerWidget {
  const _FoldKnob({
    required this.id,
    required this.count,
    required this.shut,
    required this.face,
  });

  final String id;
  final int count;
  final bool shut;
  final double face;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final what = overviewSubSessionCount(count);
    final label = shut ? 'Show $what' : 'Fold $what';
    return Semantics(
      button: true,
      expanded: !shut,
      label: label,
      excludeSemantics: true,
      child: Tooltip(
        message: label,
        child: InkResponse(
          key: ValueKey('overview-tree-knob:$id'),
          onTap: () =>
              ref.read(overviewFoldedParentsProvider.notifier).toggle(id),
          radius: face / 2,
          child: Center(
            child: Container(
              width: face,
              height: face,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: scheme.surfaceContainerHigh,
                border: Border.all(
                  color: scheme.outlineVariant,
                  width: Chrome.treeLine,
                ),
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  shut ? '$count' : '−',
                  maxLines: 1,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
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

/// A folded family's sub-sessions as one strip on the root's elbow: their
/// avatars stacked, what they are, and Show. A pointer fans the stack out.
class _FoldedStrip extends ConsumerStatefulWidget {
  const _FoldedStrip({
    required this.rootId,
    required this.below,
    required this.height,
  });

  final String rootId;
  final List<OverviewCard> below;
  final double height;

  @override
  ConsumerState<_FoldedStrip> createState() => _FoldedStripState();
}

class _FoldedStripState extends ConsumerState<_FoldedStrip> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final touch = UiDensity.of(context).isTouch;
    final fanned = _hovered && !touch;
    final summary = overviewFoldedSummary(widget.below);
    return Semantics(
      button: true,
      expanded: false,
      label: 'Show ${overviewSubSessionCount(widget.below.length)}',
      value: summary,
      excludeSemantics: true,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Material(
          color: fanned ? scheme.surfaceContainer : scheme.surfaceContainerLow,
          shape: StadiumBorder(
            side: BorderSide(
              color: fanned ? scheme.outline : scheme.outlineVariant,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: ValueKey('overview-tree-strip:${widget.rootId}'),
            onTap: () => ref
                .read(overviewFoldedParentsProvider.notifier)
                .toggle(widget.rootId),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: touch && Touch.target > widget.height
                    ? Touch.target
                    : widget.height,
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  Insets.xs,
                  Insets.xs,
                  Insets.md,
                  Insets.xs,
                ),
                child: Row(
                  children: [
                    _AvatarStack(
                      cards: widget.below,
                      size: Chrome.stackAvatar,
                      fanned: fanned,
                    ),
                    const SizedBox(width: Insets.sm),
                    Expanded(
                      child: Text(
                        summary,
                        key: ValueKey(
                          'overview-tree-folded-summary:${widget.rootId}',
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(width: Insets.sm),
                    Text(
                      'Show',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Up to four avatars overlapping, in their state rings, then "+N";
/// [fanned] spreads them apart.
class _AvatarStack extends StatelessWidget {
  const _AvatarStack({
    required this.cards,
    required this.size,
    this.fanned = false,
  });

  final List<OverviewCard> cards;
  final double size;
  final bool fanned;

  static const _most = 4;

  /// How much of each avatar the next one leaves showing, stacked.
  static const _showing = 0.6;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final motion = Motion.of(context);
    final shown = cards.take(_most).toList();
    final rest = cards.length - shown.length;
    final step = fanned ? size + Insets.xxs : size * _showing;
    final faces = <Widget>[
      for (final card in shown)
        SessionAvatar(card: card, size: size, plain: true),
      if (rest > 0)
        Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          padding: const EdgeInsets.all(Insets.xxs),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: scheme.surfaceContainerHigh,
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text('+$rest', style: theme.textTheme.labelSmall),
          ),
        ),
    ];
    return ExcludeSemantics(
      child: AnimatedContainer(
        duration: motion.fast,
        curve: Motion.standard,
        width: size + step * (faces.length - 1),
        height: size,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            for (final (i, face) in faces.indexed)
              AnimatedPositioned(
                duration: motion.fast,
                curve: Motion.standard,
                left: step * i,
                top: 0,
                child: face,
              ),
          ],
        ),
      ),
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

/// The hover's Message: a composer for one sub-session, attached under its
/// pill. Esc closes it, and so does a send.
class _TreeComposer extends StatelessWidget {
  const _TreeComposer({
    required this.card,
    required this.tuck,
    required this.line,
    required this.onClose,
    required this.onSent,
  });

  final OverviewCard card;
  final double tuck;
  final Color line;
  final VoidCallback onClose;
  final ValueChanged<QuickMessageSent> onSent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: EdgeInsets.only(left: tuck + Insets.sm),
      child: Container(
        key: ValueKey('overview-tree-composer:${card.id}'),
        padding: const EdgeInsets.all(Insets.sm),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          border: Border.all(color: line),
          borderRadius: const BorderRadius.vertical(
            bottom: Radius.circular(Radii.lg),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            OverviewQuickComposer(
              card: card,
              autofocus: true,
              onEscape: onClose,
              onSent: onSent,
            ),
            const SizedBox(height: Insets.xs),
            Text(
              'Enter sends · Shift+Enter new line · Esc closes',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A sub-session opened on the tree: all it last said, its step and diff, a
/// waiting question answered in place, a message to it, and its actions —
/// Archive, Hand back, Open chat, End and the session menu.
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
              OverviewQuickComposer(card: card),
              const SizedBox(height: Insets.sm),
              OverviewCloseActions(
                card: card,
                merge: false,
                extra: [
                  FilledButton.tonal(
                    key: ValueKey('overview-tree-open:${card.id}'),
                    style: UiDensity.of(context).compactButton,
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

/// A branch hung straight under its parent: the stem down to its avatar —
/// and on past it, unless it is the [last].
class _RunPainter extends CustomPainter {
  _RunPainter({
    required this.x,
    required this.last,
    required this.to,
    required this.color,
  });

  final double x;
  final bool last;
  final double to;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawLine(
      Offset(x, 0),
      Offset(x, last ? to : size.height),
      _line(color),
    );
  }

  @override
  bool shouldRepaint(_RunPainter old) =>
      old.x != x || old.last != last || old.to != to || old.color != color;
}

Paint _line(Color color) => Paint()
  ..color = color
  ..style = PaintingStyle.stroke
  ..strokeWidth = Chrome.treeLine
  ..strokeCap = StrokeCap.round;
