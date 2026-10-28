import 'dart:async';

import 'package:agent_cli/descriptors.dart' show AgentActivityStatus;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/widgets/truncated_text.dart';
import '../../../core/capabilities/capabilities.dart';
import '../../../core/util/clock_provider.dart';
import '../../explorer/application/agent_states.dart';
import '../../sessions/application/session_status_providers.dart';
import '../../sessions/application/session_turn_interrupt.dart';
import '../../sessions/application/session_turn_stop.dart';
import '../../sessions/presentation/stop_children_offer.dart';
import '../application/overview_batch.dart';
import '../application/overview_board.dart';
import '../application/overview_drawer.dart';
import '../application/overview_family_order.dart';
import '../application/overview_links.dart';
import '../application/overview_prefs.dart';
import '../application/overview_providers.dart';
import '../application/overview_reads.dart';
import '../application/overview_seen.dart';
import '../application/overview_tree.dart';
import 'overview_batch_bar.dart';
import 'overview_card_links.dart';
import 'overview_card_parts.dart';
import 'overview_done_card.dart';
import 'overview_end_button.dart';
import 'overview_quick_composer.dart';
import 'overview_resume_actions.dart';
import 'overview_session_parts.dart';
import 'session_avatar.dart';

/// **A family on the dashboard**: one card of fixed slots — the parent's
/// avatar and header, its sub-sessions on a stem in spawn order, and a
/// footer — that a change of state never resizes. [compact] draws the
/// phone's smaller avatars; [wide] adds the agent and start time.
class OverviewFamilyTree extends ConsumerStatefulWidget {
  const OverviewFamilyTree({
    required this.node,
    required this.onOpen,
    this.compact = false,
    this.wide = false,
    this.laneKey,
    this.laneRoots = const [],
    this.matches,
    super.key,
  });

  /// What the dashboard's search matches, null while it is empty: a family
  /// holding a match unfolds whole, and its other rows dim.
  final Set<String>? matches;

  final OverviewTreeNode node;
  final ValueChanged<OverviewCard> onOpen;
  final bool compact;
  final bool wide;

  /// The lane it sits in and that lane's roots as drawn, for Move earlier
  /// and later and the drag that reorders them.
  final String? laneKey;
  final List<String> laneRoots;

  /// The sub-session rows drawn before the rest fold into one.
  static const shownRows = 4;

  @override
  ConsumerState<OverviewFamilyTree> createState() => _OverviewFamilyTreeState();
}

class _OverviewFamilyTreeState extends ConsumerState<OverviewFamilyTree> {
  /// The rows past [OverviewFamilyTree.shownRows] are drawn too.
  var _showAll = false;

  /// The header holds the keys: the card's outline says so.
  final _headFocused = ValueNotifier(false);

  @override
  void dispose() {
    _headFocused.dispose();
    super.dispose();
  }

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
    final node = widget.node;
    final root = node.card;
    final matches = widget.matches ?? const <String>{};
    final found = node.drawn.any((c) => matches.contains(c.id));
    // A match below the root, folded away or past the cap, is drawn.
    final opened = found && node.descendants.any((c) => matches.contains(c.id));
    final watched = ref.watch(overviewFoldedParentsProvider);
    final folded = opened
        ? watched.difference({for (final c in node.drawn) c.id})
        : watched;
    final focused = ref.watch(
      overviewFocusProvider.select((f) => f.peeked ?? f.selected),
    );
    final selected = ref.watch(
      overviewFocusProvider.select((f) => f.selected == root.id),
    );
    final line = scheme.outlineVariant;
    final surface = scheme.surfaceContainerLowest;
    final pad = widget.compact ? Insets.sm : Insets.md;

    final below = overviewDrawnOf(node, folded).skip(1).toList();
    final shut = node.children.isNotEmpty && folded.contains(root.id);
    const cap = OverviewFamilyTree.shownRows;
    final long = below.length > cap + 1;
    // A session picked past the cap is never left out of view.
    final pickedPast = below.skip(cap).any((c) => c.id == focused);
    final capped = long && !_showAll && !pickedPast && !opened;
    final hidden = <OverviewCard>[];
    var budget = capped ? cap : below.length;

    Widget subtree(
      OverviewTreeNode node, {
      required bool isRoot,
      OverviewCard? parent,
      int depth = 0,
    }) {
      final size = isRoot ? _rootSize : _kidSize;
      final id = node.card.id;
      final under = node.descendants.toList();
      final inner = !isRoot && under.isNotEmpty && folded.contains(id);
      Widget head = isRoot
          ? _rootHead(node, surface)
          : _TreePill(
              key: ValueKey('overview-tree-node:$id'),
              node: node,
              parent: parent,
              size: size,
              halo: surface,
              hidden: inner ? under : null,
              onOpen: () => widget.onOpen(node.card),
            );
      if (found && !matches.contains(id)) {
        head = Opacity(opacity: StateLayers.dimmedOpacity, child: head);
      }
      if (under.isNotEmpty) {
        head = _withKnob(
          head,
          id: id,
          size: size,
          count: under.length,
          shut: isRoot ? shut : inner,
        );
      }
      final branches = <(Key?, Widget)>[];
      if (isRoot && shut) {
        branches.add((
          null,
          _SummaryRow(
            key: ValueKey('overview-tree-strip:$id'),
            textKey: ValueKey('overview-tree-folded-summary:$id'),
            lead: overviewSubSessionCount(under.length),
            cards: under,
            height: _kidSize,
            open: false,
            onTap: () =>
                ref.read(overviewFoldedParentsProvider.notifier).toggle(id),
          ),
        ));
      } else if (!inner) {
        for (final kid in node.children) {
          if (budget <= 0) {
            hidden.addAll(overviewDrawnOf(kid, folded));
            continue;
          }
          budget--;
          branches.add((
            ValueKey('overview-tree-branch:${kid.card.id}'),
            subtree(kid, isRoot: false, parent: node.card, depth: depth + 1),
          ));
        }
      }
      if (isRoot && !shut && long && (hidden.isNotEmpty || _showAll)) {
        branches.add((
          null,
          _SummaryRow(
            key: ValueKey('overview-tree-more:$id'),
            textKey: ValueKey('overview-tree-more-line:$id'),
            lead: hidden.isEmpty ? 'Show fewer' : '${hidden.length} more',
            cards: hidden,
            height: _kidSize,
            open: hidden.isEmpty,
            onTap: () => setState(() => _showAll = hidden.isNotEmpty),
          ),
        ));
      }
      final stemAt = size / 2 - Chrome.treeLine / 2;
      final elbowAt = Insets.sm + _kidSize / 2;
      // Past the deepest step in, a sub-session hangs straight under its
      // parent.
      final flat = depth >= Chrome.treeIndentDepth;
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
                              to: Insets.sm,
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
                          top: Insets.sm,
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

    final tree = subtree(node, isRoot: true);
    return Semantics(
      container: true,
      label: node.children.isEmpty
          ? root.entry.title
          : '${root.entry.title} and its sub-sessions',
      child: _FamilyFrame(
        card: root,
        inside: {for (final c in node.descendants) c.id},
        selected: selected,
        headFocused: _headFocused,
        pad: pad,
        surface: surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            OverviewParentLink(card: root),
            tree,
            const SizedBox(height: Insets.xs),
            _FamilyFooter(
              node: node,
              text: _rootSize + Insets.sm,
              laneKey: widget.laneKey,
              laneRoots: widget.laneRoots,
            ),
          ],
        ),
      ),
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

  /// The parent's avatar inside the card, its header beside it.
  Widget _rootHead(OverviewTreeNode node, Color surface) {
    final card = node.card;
    final size = _rootSize;
    return _RootHead(
      node: node,
      size: size,
      halo: surface,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: size),
        child: Padding(
          padding: EdgeInsets.only(left: size + Insets.sm),
          // Lit, it is the card's outline that turns the accent.
          child: OverviewFamilyHover(
            card: card,
            ring: false,
            child: _FamilyHeader(
              node: node,
              onOpen: widget.onOpen,
              wide: widget.wide,
              onFocus: (on) => _headFocused.value = on,
            ),
          ),
        ),
      ),
    );
  }
}

/// A family card's surface and its one outline, along the card's own
/// rounded edge: the accent, wider, when it is selected, its header holds
/// the keys, or a sub-session drawn elsewhere lights it; [Theme]'s outline
/// under a pointer; the quiet outline otherwise. Drawn over the edge, so
/// nothing moves. A sub-session inside the card lighting its parent rings
/// nothing: the pointer or the keys are in the card already, and the
/// parent's avatar glows instead.
class _FamilyFrame extends ConsumerStatefulWidget {
  const _FamilyFrame({
    required this.card,
    required this.inside,
    required this.selected,
    required this.headFocused,
    required this.pad,
    required this.surface,
    required this.child,
  });

  final OverviewCard card;

  /// The sub-sessions this card draws, or folds away.
  final Set<String> inside;
  final bool selected;
  final ValueNotifier<bool> headFocused;
  final double pad;
  final Color surface;
  final Widget child;

  @override
  ConsumerState<_FamilyFrame> createState() => _FamilyFrameState();
}

class _FamilyFrameState extends ConsumerState<_FamilyFrame> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) {
    final card = widget.card;
    final scheme = Theme.of(context).colorScheme;
    final touch = UiDensity.of(context).isTouch;
    final lit = ref.watch(
      overviewLinkFocusProvider.select(
        (f) => overviewLinkLit(card, f) && !widget.inside.contains(f!.id),
      ),
    );
    final radius = BorderRadius.circular(Radii.lg);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: ValueListenableBuilder<bool>(
        valueListenable: widget.headFocused,
        builder: (context, focused, child) {
          final ringed = widget.selected || lit || focused;
          return Container(
            key: ValueKey('overview-family:${card.id}'),
            // The footer's target is taller than its buttons: the card's
            // bottom edge gives back that slack, so the space under them
            // reads as the space over the avatar.
            padding: EdgeInsets.fromLTRB(
              widget.pad,
              widget.pad,
              widget.pad,
              Insets.xs,
            ),
            decoration: BoxDecoration(
              color: widget.surface,
              borderRadius: radius,
              border: Border.all(
                color: _hovered && !touch
                    ? scheme.outline
                    : scheme.outlineVariant,
              ),
            ),
            // Always there, so lighting it never remounts the card and takes
            // the keys from a row inside it.
            foregroundDecoration: BoxDecoration(
              borderRadius: radius,
              border: ringed
                  ? Border.all(
                      color: scheme.primary,
                      width: StateLayers.focusRingWidth * 2,
                    )
                  : null,
            ),
            child: child,
          );
        },
        child: widget.child,
      ),
    );
  }
}

/// How many of [node]'s sub-sessions have finished their turn: ready or
/// ended, as its avatar's ring counts them.
int overviewFinishedBelow(OverviewTreeNode node) => node.descendants
    .where((c) => c.state == AgentState.ready || c.state == AgentState.ended)
    .length;

/// The height of [lines] lines of [style] under the ambient text scale.
double overviewLinesHeight(BuildContext context, TextStyle? style, int lines) {
  final painter = TextPainter(
    text: TextSpan(text: 'Ag', style: style),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final height = painter.height * lines;
  painter.dispose();
  return height;
}

/// A family's header: its title, new count, pin and state in a fixed slot;
/// "2/4 finished" with, on [wide], the agent and start; then two lines of
/// what it last said or asks.
class _FamilyHeader extends ConsumerWidget {
  const _FamilyHeader({
    required this.node,
    required this.onOpen,
    required this.wide,
    required this.onFocus,
  });

  final OverviewTreeNode node;
  final ValueChanged<OverviewCard> onOpen;
  final bool wide;

  /// It took or lost the keys: the card, not the header, draws the ring.
  final ValueChanged<bool> onFocus;

  /// The most of the meta line "2/4 finished" and the agent take, wide.
  static const _metaShare = 0.5;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final card = node.card;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final density = UiDensity.of(context);
    final touch = density.isTouch;
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final pinned = ref.watch(
      overviewPrefsProvider.select((p) => p.pinned.contains(card.id)),
    );
    final agent = watchOverviewAgentName(ref, card);
    final place = watchOverviewCardPlace(ref, card);
    final kids = node.descendants.length;
    final started = MaterialLocalizations.of(
      context,
    ).formatTimeOfDay(TimeOfDay.fromDateTime(card.entry.createdAt.toLocal()));
    // Where it runs comes before the agent: it is what "Show on cards" asks
    // for, so it holds on a phone too.
    final meta = [
      if (kids > 0) '${overviewFinishedBelow(node)}/$kids finished',
      if (place.isNotEmpty) place,
      if (wide) ...[?agent, 'started $started'],
    ].join(' · ');
    final titleStyle = theme.textTheme.bodyMedium?.copyWith(
      fontWeight: FontWeight.w600,
    );
    final slot = WidthClass.scaleBreakpoint(
      Chrome.familyStateSlot,
      MediaQuery.textScalerOf(context),
    );
    final asks = overviewWaitingIn(node);
    return Material(
      type: MaterialType.transparency,
      child: Semantics(
        hint: 'Open chat',
        onTapHint: 'Open chat',
        child: InkWell(
          key: ValueKey('overview-family-head:${card.id}'),
          // No box of its own behind the title and text: hover, focus and a
          // press show on the card's outline, along the card's shape.
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          splashFactory: NoSplash.splashFactory,
          onFocusChange: onFocus,
          // The card's tap is its Open chat: there is no button for it.
          onTap: () {
            if (!overviewPickSelects(ref, card, touch: touch)) onOpen(card);
          },
          onLongPress: () => overviewPickSelects(ref, card, long: true),
          onSecondaryTapUp: (details) => showOverviewFamilyMenu(
            context,
            ref,
            node,
            at: details.globalPosition,
          ),
          child: OverviewHoverScope(
            child: LayoutBuilder(
              builder: (context, box) {
                final stateWidth = slot.clamp(0.0, box.maxWidth / 3);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        // The new count and pin follow the title, not the
                        // state's slot: the title gives up its width first.
                        Expanded(
                          child: Row(
                            children: [
                              Flexible(
                                child: Semantics(
                                  header: true,
                                  label: [
                                    card.entry.title,
                                    card.state.label,
                                    ?agent,
                                    if (place.isNotEmpty) place,
                                  ].join(', '),
                                  excludeSemantics: true,
                                  child: TruncatedText(
                                    card.entry.title,
                                    textKey: ValueKey(
                                      'overview-card-title:${card.id}',
                                    ),
                                    triggerMode: TooltipTriggerMode.manual,
                                    style: titleStyle,
                                  ),
                                ),
                              ),
                              const SizedBox(width: Insets.xs),
                              OverviewNewBadge(card: card),
                              if (pinned) ...[
                                const SizedBox(width: Insets.xs),
                                Icon(
                                  AppIcons.pushPinFill,
                                  key: ValueKey(
                                    'overview-family-pinned:${card.id}',
                                  ),
                                  size: density.iconSmall,
                                  color: scheme.primary,
                                  semanticLabel: 'Pinned',
                                ),
                              ],
                              if (asks > 0) ...[
                                const SizedBox(width: Insets.xs),
                                _AskMarker(
                                  card: card,
                                  asks: asks,
                                  height: overviewLinesHeight(
                                    context,
                                    titleStyle,
                                    1,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: Insets.xs),
                        SizedBox(
                          key: ValueKey('overview-family-state:${card.id}'),
                          width: stateWidth,
                          child: Align(
                            alignment: AlignmentDirectional.centerEnd,
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: AlignmentDirectional.centerEnd,
                              child: OverviewStatePill(card: card),
                            ),
                          ),
                        ),
                      ],
                    ),
                    // One fixed line: wide, the plan step, diff and check
                    // follow, each cut short rather than wrapping.
                    SizedBox(
                      height: overviewLinesHeight(context, muted, 1),
                      child: ClipRect(
                        child: Row(
                          children: [
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: wide
                                    ? box.maxWidth * _metaShare
                                    : box.maxWidth,
                              ),
                              child: Text(
                                meta,
                                key: ValueKey(
                                  'overview-family-meta:${card.id}',
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: muted,
                              ),
                            ),
                            if (wide) ...[
                              if (meta.isNotEmpty)
                                const SizedBox(width: Insets.md),
                              Expanded(
                                child: Align(
                                  alignment: AlignmentDirectional.centerStart,
                                  child: OverviewMetaLine(
                                    card: card,
                                    oneLine: true,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: Insets.xxs),
                    _SayLines(card: card),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// **What waits on you in a family**, beside its title: the count in the
/// attention colour, which opens the waiting drawer on this family. No
/// taller than the title's line, so its coming and going moves nothing.
class _AskMarker extends ConsumerWidget {
  const _AskMarker({
    required this.card,
    required this.asks,
    required this.height,
  });

  final OverviewCard card;
  final int asks;
  final double height;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final words = 'Review $asks ${asks == 1 ? 'ask' : 'asks'}';
    final radius = BorderRadius.circular(Radii.pill);
    return Tooltip(
      message: words,
      child: Semantics(
        button: true,
        label: words,
        excludeSemantics: true,
        child: Material(
          type: MaterialType.transparency,
          borderRadius: radius,
          child: InkWell(
            key: ValueKey('overview-family-review:${card.id}'),
            borderRadius: radius,
            onTap: () =>
                ref.read(overviewDrawerProvider.notifier).open(family: card.id),
            child: SizedBox(
              height: height,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: OverviewStateChip(
                  state: AgentState.needsYou,
                  label: '$asks ${asks == 1 ? 'ask' : 'asks'}',
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Exactly two lines: what [card] asks, in the attention colour, or the
/// latest thing it said, or what it is doing while it has said nothing.
class _SayLines extends ConsumerWidget {
  const _SayLines({required this.card});

  final OverviewCard card;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall;
    final asks = card.column == BoardColumn.needsYou && !card.heldBySubSessions;
    final said = ref.watch(overviewLastAnswerProvider(card.id)).value?.text;
    final Widget body;
    if (asks) {
      body = Text(
        watchOverviewLine(ref, card),
        key: ValueKey('overview-family-ask:${card.id}'),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: style?.copyWith(color: SemanticColors.of(context).attention),
      );
    } else if (said != null) {
      body = OverviewLatestMessage(sessionId: card.id);
    } else {
      body = Text(
        watchOverviewLine(ref, card),
        key: ValueKey('overview-tree-line:${card.id}'),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: style?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      );
    }
    return SizedBox(
      height: overviewLinesHeight(context, style, 2),
      child: ClipRect(
        child: Align(alignment: AlignmentDirectional.topStart, child: body),
      ),
    );
  }
}

/// A family's footer, one fixed height and the same three slots in every
/// state, so nothing moves sideways: the drag handle at its start, then, at
/// the card's end, ⋯, Stop (Archive once it ended) and Message. Message
/// turns the footer itself into a one-line message box, the same height, so
/// the card never resizes. Opening the chat is the card's own tap.
class _FamilyFooter extends ConsumerStatefulWidget {
  const _FamilyFooter({
    required this.node,
    required this.text,
    required this.laneKey,
    required this.laneRoots,
  });

  final OverviewTreeNode node;

  /// Where the header's text column starts, from the card's content edge.
  final double text;
  final String? laneKey;
  final List<String> laneRoots;

  @override
  ConsumerState<_FamilyFooter> createState() => _FamilyFooterState();
}

class _FamilyFooterState extends ConsumerState<_FamilyFooter> {
  /// The message box is open in place of the buttons.
  var _replying = false;

  void _close() {
    if (mounted) setState(() => _replying = false);
  }

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final laneKey = widget.laneKey;
    final laneRoots = widget.laneRoots;
    final card = node.card;
    if (_replying) {
      return SizedBox(
        key: ValueKey('overview-family-reply-box:${card.id}'),
        height: Touch.target,
        child: Padding(
          padding: EdgeInsetsDirectional.only(start: widget.text),
          child: OverviewQuickComposer(
            card: card,
            oneLine: true,
            autofocus: true,
            onEscape: _close,
            onSent: (_) => _close(),
          ),
        ),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    final density = UiDensity.of(context);
    final compact = density.compactButton;
    final scaler = MediaQuery.textScalerOf(context);
    final messageSlot = WidthClass.scaleBreakpoint(
      Chrome.familyPrimarySlot,
      scaler,
    );
    final sideSlot = WidthClass.scaleBreakpoint(
      Chrome.familySecondarySlot,
      scaler,
    );
    final drag = !density.isTouch && laneKey != null && laneRoots.length > 1;
    final caps = ref.watch(capabilitiesProvider);
    final ended = card.state == AgentState.ended;
    // Message resumes an ended session through the same send, where this
    // client may start one.
    final noMessage = !caps.maySend
        ? kPromptNotGranted
        : ended && !caps.mayStart
        ? kStartNotGranted
        : null;
    final stop = _stopState(card, caps);
    Widget label(String text) =>
        Text(text, maxLines: 1, overflow: TextOverflow.ellipsis);
    final menu = Builder(
      builder: (button) => Tooltip(
        message: 'More',
        // A button's face, Stop's and Message's own, not a glyph that reads
        // as text.
        child: OutlinedButton(
          key: ValueKey('overview-card-menu:${card.id}'),
          style: (compact ?? const ButtonStyle()).copyWith(
            padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: Insets.sm),
            ),
            foregroundColor: WidgetStatePropertyAll(scheme.onSurfaceVariant),
          ),
          onPressed: () => showOverviewFamilyMenu(
            button,
            ref,
            node,
            laneKey: laneKey,
            laneRoots: laneRoots,
          ),
          child: Icon(
            AppIcons.dotsThree,
            size: density.iconSize(Chrome.icon),
            semanticLabel: 'More',
          ),
        ),
      ),
    );
    return SizedBox(
      height: Touch.target,
      child: LayoutBuilder(
        builder: (context, box) {
          final lead = drag ? Chrome.control : 0.0;
          // ⋯'s face, its gaps and the two slots; where they do not fit, as
          // on a phone at large text, Stop and Archive draw as icons and
          // Message takes what is left.
          const gaps = Insets.xs * 2;
          final room = box.maxWidth - lead - Touch.target - gaps;
          final iconOnly = messageSlot + sideSlot > room;
          final side = iconOnly ? Touch.target : sideSlot;
          final message = (iconOnly ? room - side : messageSlot).clamp(
            0.0,
            messageSlot,
          );
          final Widget secondary;
          if (ended) {
            final family = node.children.isNotEmpty;
            final left = overviewFamilyToArchive(node);
            secondary = OverviewArchiveGate(
              sessionId: card.id,
              builder: (resuming) {
                final key = ValueKey(
                  family
                      ? 'overview-archive-family:${card.id}'
                      : 'overview-done-archive:${card.id}',
                );
                final onPressed = resuming || left.isEmpty
                    ? null
                    : () => unawaited(
                        archiveFamilyFromDashboard(context, ref, node),
                      );
                return Tooltip(
                  message: family ? 'Archive the family' : 'Archive',
                  child: iconOnly
                      ? OutlinedButton(
                          key: key,
                          style: _iconFace(compact),
                          onPressed: onPressed,
                          child: Icon(
                            AppIcons.tray,
                            size: density.iconSize(Chrome.icon),
                            semanticLabel: 'Archive',
                          ),
                        )
                      : OutlinedButton(
                          key: key,
                          style: compact,
                          onPressed: onPressed,
                          child: label('Archive'),
                        ),
                );
              },
            );
          } else {
            final key = ValueKey('overview-interrupt:${card.id}');
            final onPressed = stop.why == null
                ? () => _interrupt(context, card)
                : null;
            secondary = Tooltip(
              message: stop.why ?? 'Stop this turn; the session keeps running',
              child: iconOnly
                  ? OutlinedButton(
                      key: key,
                      style: _iconFace(compact),
                      onPressed: onPressed,
                      child: Icon(
                        AppIcons.stop,
                        size: density.iconSize(Chrome.icon),
                        semanticLabel: 'Stop',
                      ),
                    )
                  : OutlinedButton(
                      key: key,
                      style: compact,
                      onPressed: onPressed,
                      child: label('Stop'),
                    ),
            );
          }
          final send = FilledButton.tonal(
            key: ValueKey('overview-family-message:${card.id}'),
            style: compact,
            onPressed: noMessage == null
                ? () => setState(() => _replying = true)
                : null,
            child: label('Message'),
          );
          return Row(
            children: [
              SizedBox(
                width: lead,
                child: drag
                    ? Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: _DragHandle(card: card),
                      )
                    : null,
              ),
              const Spacer(),
              menu,
              const SizedBox(width: Insets.xs),
              SizedBox(
                key: ValueKey('overview-family-secondary:${card.id}'),
                width: side,
                child: Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: SizedBox(width: side, child: secondary),
                ),
              ),
              const SizedBox(width: Insets.xs),
              SizedBox(
                key: ValueKey('overview-family-primary:${card.id}'),
                width: message,
                child: Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: SizedBox(
                    width: message,
                    child: noMessage == null
                        ? send
                        : Tooltip(message: noMessage, child: send),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// A Stop or Archive drawn as its icon alone: a square face.
  ButtonStyle _iconFace(ButtonStyle? compact) =>
      (compact ?? const ButtonStyle()).copyWith(
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        minimumSize: const WidgetStatePropertyAll(Size.square(Chrome.control)),
      );

  /// Whether Stop may interrupt [card] now, and why not when it may not.
  /// A turn runs while it works, or waits on an approval inside its turn;
  /// a parent drawn at work for its sub-sessions has none of its own.
  ({String? why}) _stopState(OverviewCard card, Capabilities caps) {
    final working = ref.watch(sessionTurnWorkingProvider(card.id));
    final approving =
        card.state == AgentState.needsYou &&
        ref.watch(
          agentSessionStatusProvider(card.id).select(
            (s) =>
                s.asData?.value.turnStatus ==
                AgentActivityStatus.awaitingApproval,
          ),
        );
    final running =
        working ||
        approving ||
        (card.waitingOn == null &&
            (card.state == AgentState.working ||
                card.state == AgentState.quiet));
    if (!caps.maySend) return (why: kPromptNotGranted);
    if (!running) return (why: 'No turn is running');
    return (why: null);
  }

  /// **Stop**: the chat's own interrupt — an Esc, or the protocol's cancel —
  /// never End; the session stays up for the next message.
  void _interrupt(BuildContext context, OverviewCard card) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    offerToStopChildren(context, ref, card.id);
    unawaited(
      ref.read(sessionTurnInterruptProvider)(card.id).then((why) {
        if (why != null) {
          messenger?.showSnackBar(SnackBar(content: Text(why)));
        }
      }),
    );
  }
}

/// The ⋮⋮ a family is dragged by to another place in its lane.
class _DragHandle extends StatelessWidget {
  const _DragHandle({required this.card});

  final OverviewCard card;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final density = UiDensity.of(context);
    final icon = Icon(
      AppIcons.dotsSixVertical,
      size: density.iconSize(Chrome.iconSmall),
      color: scheme.onSurfaceVariant,
    );
    return Draggable<String>(
      key: ValueKey('overview-family-drag:${card.id}'),
      data: card.id,
      feedback: Material(
        elevation: Elevations.popup,
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(Radii.md),
        child: Padding(
          padding: const EdgeInsets.all(Insets.sm),
          child: Text(card.entry.title, style: theme.textTheme.bodyMedium),
        ),
      ),
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: Tooltip(
          message: 'Drag to move it in its lane',
          child: SizedBox(
            width: Chrome.control,
            height: Chrome.control,
            child: Center(child: icon),
          ),
        ),
      ),
    );
  }
}

/// [node]'s menu — the card's own verbs, its place in the lane, Mark seen,
/// Merge and Hand back where they apply, then the shared session menu.
Future<void> showOverviewFamilyMenu(
  BuildContext anchor,
  WidgetRef ref,
  OverviewTreeNode node, {
  String? laneKey,
  List<String> laneRoots = const [],
  Offset? at,
}) {
  final card = node.card;
  final at0 = laneRoots.indexOf(card.id);
  final movable = laneKey != null && at0 >= 0 && laneRoots.length > 1;
  final merge = overviewMergeOffer(ref, card);
  final parent = overviewHandBackParent(ref, card);
  return showOverviewCardMenu(
    anchor,
    ref,
    card,
    at: at,
    more: [
      if (movable) ...[
        DesktopMenuItem(
          key: const ValueKey('overview-card-menu:earlier'),
          value: 'board-earlier',
          label: 'Move earlier',
          icon: AppIcons.arrowUp,
          enabled: at0 > 0,
        ),
        DesktopMenuItem(
          key: const ValueKey('overview-card-menu:later'),
          value: 'board-later',
          label: 'Move later',
          icon: AppIcons.arrowDown,
          enabled: at0 < laneRoots.length - 1,
        ),
      ],
      DesktopMenuItem(
        key: const ValueKey('overview-card-menu:seen'),
        value: 'board-seen',
        label: 'Mark seen',
        icon: AppIcons.eye,
      ),
      if (card.entry.native != null)
        DesktopMenuItem(
          key: const ValueKey('overview-card-menu:merge'),
          value: 'board-merge',
          label: 'Merge',
          icon: AppIcons.gitMerge,
          enabled: merge != null && merge.isEnabled,
        ),
      if (parent != null)
        DesktopMenuItem(
          key: const ValueKey('overview-card-menu:hand-back'),
          value: 'board-hand-back',
          label: 'Hand back to ${parent.entry.title}',
          icon: AppIcons.arrowBendDownRight,
        ),
    ],
    // The shared End, where it stands, but the card's own: asked first,
    // since Stop beside it only interrupts.
    replace: {
      'end': DesktopMenuItem(
        key: ValueKey('overview-end:${card.id}'),
        value: 'board-end',
        label: 'End session…',
        icon: AppIcons.power,
      ),
    },
    onMore: (value) async {
      switch (value) {
        case 'board-end':
          await endFromDashboard(anchor, ref, card, confirm: true);
        case 'board-earlier' || 'board-later':
          ref
              .read(overviewFamilyOrderProvider.notifier)
              .step(
                laneKey!,
                laneRoots,
                card.id,
                value == 'board-earlier' ? -1 : 1,
              );
        case 'board-seen':
          final now = ref.read(clockProvider).nowUtc();
          final seen = ref.read(overviewSeenProvider.notifier);
          for (final member in node.drawn) {
            seen.markSeen(member.id, now);
          }
        case 'board-merge' when merge != null:
          await mergeFromDashboard(anchor, ref, card, merge);
        case 'board-hand-back' when parent != null:
          await handBackFromDashboard(anchor, ref, card, parent);
        default:
          return false;
      }
      return true;
    },
  );
}

/// A family's parent avatar at the card's top left, the pick box on its
/// face as a pill's is: while picking, or under a pointer over it.
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

  /// The header, beside the avatar.
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
    // A sub-session of its own under a pointer or the keys: the quiet
    // "this is its parent", its ring glowing as the hovered one's does.
    final lit = ref.watch(
      overviewLinkFocusProvider.select((f) => overviewLinkLit(card, f)),
    );
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
                  glow: lit,
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

/// **A sub-session on the tree**, one fixed-height row: its avatar, its
/// title, its state in a fixed slot and one line of preview. A tap, Enter
/// or Space opens it in the peek; a pointer over it slides it and lights
/// its avatar.
class _TreePill extends ConsumerStatefulWidget {
  const _TreePill({
    required this.node,
    required this.size,
    required this.halo,
    required this.onOpen,
    this.parent,
    this.hidden,
    super.key,
  });

  final OverviewTreeNode node;

  /// The session it branches off: where it runs is said only where that
  /// differs.
  final OverviewCard? parent;
  final double size;
  final Color halo;
  final VoidCallback onOpen;

  /// What its fold hides, said in place of its latest line.
  final List<OverviewCard>? hidden;

  @override
  ConsumerState<_TreePill> createState() => _TreePillState();
}

class _TreePillState extends ConsumerState<_TreePill> {
  var _hovered = false;
  var _pressed = false;
  var _focused = false;

  /// The keys are on the pill or its pick box.
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
    final size = widget.size;
    final tuck = size / 2;
    final apart = widget.parent == null
        ? ''
        : watchOverviewPlaceApart(ref, card, widget.parent!);
    // Its family lit by a pointer or the keys elsewhere turns its own outline
    // the accent: one line, never a ring drawn round it and its avatar.
    final lit = ref.watch(
      overviewLinkFocusProvider.select((f) => overviewLinkLit(card, f)),
    );
    final ringed = _focused || selected || lit;
    final edge = ringed
        ? scheme.primary
        : hovered
        ? scheme.outline
        : scheme.outlineVariant;
    final minHeight = touch && Touch.target > size ? Touch.target : size;
    final slot = WidthClass.scaleBreakpoint(
      Chrome.familyStateSlot,
      MediaQuery.textScalerOf(context),
    );

    final pill = Material(
      color: hovered ? scheme.surfaceContainer : scheme.surfaceContainerLow,
      elevation: hovered ? Elevations.popup : 0,
      shadowColor: scheme.shadow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.lg),
        side: BorderSide(
          color: edge,
          width: ringed ? StateLayers.focusRingWidth * 2 : 1,
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
              widget.onOpen();
            }
          },
          onLongPress: () => overviewPickSelects(ref, card, long: true),
          onSecondaryTapUp: (details) => showOverviewFamilyMenu(
            context,
            ref,
            node,
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
                    final stateWidth = slot.clamp(0.0, box.maxWidth / 3);
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
                            const SizedBox(width: Insets.xs),
                            SizedBox(
                              width: stateWidth,
                              child: Align(
                                alignment: AlignmentDirectional.centerEnd,
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: AlignmentDirectional.centerEnd,
                                  child: OverviewStatePill(card: card),
                                ),
                              ),
                            ),
                          ],
                        ),
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
    return OverviewFamilyHover(
      card: card,
      ring: false,
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
    );
  }
}

/// One row for the sub-sessions not drawn — a folded family's, or those past
/// the cap: their avatars stacked and "N more · K asks · J new". A tap
/// unfolds them; [open] says the row folds them back.
class _SummaryRow extends ConsumerStatefulWidget {
  const _SummaryRow({
    required this.textKey,
    required this.lead,
    required this.cards,
    required this.height,
    required this.open,
    required this.onTap,
    super.key,
  });

  final Key textKey;
  final String lead;
  final List<OverviewCard> cards;
  final double height;
  final bool open;
  final VoidCallback onTap;

  @override
  ConsumerState<_SummaryRow> createState() => _SummaryRowState();
}

class _SummaryRowState extends ConsumerState<_SummaryRow> {
  var _hovered = false;
  var _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final density = UiDensity.of(context);
    final touch = density.isTouch;
    final fanned = _hovered && !touch;
    final cards = widget.cards;
    final asks = cards
        .where((c) => c.column == BoardColumn.needsYou && !c.heldBySubSessions)
        .length;
    final fresh = cards.where((c) => watchOverviewNewCount(ref, c) > 0).length;
    final summary = [
      widget.lead,
      if (asks > 0) '$asks ${asks == 1 ? 'ask' : 'asks'}',
      if (fresh > 0) '$fresh new',
    ].join(' · ');
    return Semantics(
      button: true,
      expanded: widget.open,
      label: summary,
      excludeSemantics: true,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Material(
          color: fanned ? scheme.surfaceContainer : scheme.surfaceContainerLow,
          // The rows' own outline: the accent, wider, holding the keys.
          shape: StadiumBorder(
            side: BorderSide(
              color: _focused
                  ? scheme.primary
                  : fanned
                  ? scheme.outline
                  : scheme.outlineVariant,
              width: _focused ? StateLayers.focusRingWidth * 2 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.onTap,
            onFocusChange: (on) => setState(() => _focused = on),
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
                    if (cards.isNotEmpty) ...[
                      _AvatarStack(
                        cards: cards,
                        size: Chrome.stackAvatar,
                        fanned: fanned,
                      ),
                      const SizedBox(width: Insets.sm),
                    ],
                    Expanded(
                      child: Text(
                        summary,
                        key: widget.textKey,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(width: Insets.sm),
                    Icon(
                      widget.open ? AppIcons.caretUp : AppIcons.caretDown,
                      size: density.iconSmall,
                      color: scheme.onSurfaceVariant,
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
