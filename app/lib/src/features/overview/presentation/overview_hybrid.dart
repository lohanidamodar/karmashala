import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/shell/phone_routes.dart';
import '../../../app/shell/phone_shell.dart' show PhoneTabsScope;
import '../../sessions/application/session_status_providers.dart';
import '../../sessions/presentation/prompt_cards/question_prompt_card.dart';
import '../application/overview_board.dart';
import '../application/overview_drawer.dart';
import '../application/overview_family_order.dart';
import '../application/overview_links.dart';
import '../application/overview_prefs.dart';
import '../application/overview_providers.dart';
import '../application/overview_search.dart';
import '../application/overview_tiles.dart' show overviewCardOf;
import '../application/overview_tree.dart';
import 'overview_card_parts.dart';
import 'overview_filters.dart';
import 'overview_glances.dart';
import 'overview_heartbeat.dart';
import 'overview_phone_strip.dart';
import 'overview_pins.dart';
import 'overview_pipeline_lane.dart';
import 'overview_queue_card.dart';
import 'overview_search_sheet.dart';
import 'overview_strip.dart';
import 'overview_tree.dart';
import 'overview_waiting_lane.dart';

/// What the Overview draws, in reading order.
typedef OverviewSections = ({
  /// What waits on you, asks before failures and oldest wait first: the
  /// waiting drawer's order, which N walks.
  List<OverviewCard> queue,

  /// Every family's sessions as drawn, lane by lane, each once: the order
  /// J and K walk.
  List<OverviewCard> families,
});

/// [board]'s sessions as the Overview lays them out: [forest]'s families in
/// their fixed places, a [folded] family's sub-sessions not drawn, and what
/// waits on you in the drawer's order.
OverviewSections overviewSectionsOf(
  OverviewBoard board,
  OverviewForest forest, {
  required DateTime? Function(String id) waitingSince,
  Set<String> folded = const {},
}) {
  final queue = [
    for (final lane in board.lanes)
      ...lane.cards(BoardColumn.needsYou).where((c) => !c.heldBySubSessions),
  ];
  DateTime since(OverviewCard card) =>
      waitingSince(card.id) ?? card.entry.activityAt;
  queue.sort((a, b) {
    final rank = overviewUrgency(a.state).compareTo(overviewUrgency(b.state));
    if (rank != 0) return rank;
    final byWait = since(a).compareTo(since(b));
    return byWait != 0 ? byWait : a.id.compareTo(b.id);
  });
  final seen = <String>{};
  return (
    queue: queue,
    families: [
      for (final (_, trees) in forest.lanes)
        for (final tree in trees)
          for (final card in overviewDrawnOf(tree, folded))
            if (seen.add(card.id)) card,
    ],
  );
}

/// The ids of the lane [id] is drawn in, in drawn order; every drawn session
/// when it is in none.
List<String> overviewLaneOf(
  OverviewForest forest,
  String? id, {
  Set<String> folded = const {},
}) {
  final lanes = [
    for (final (_, trees) in forest.lanes)
      [
        for (final tree in trees)
          for (final card in overviewDrawnOf(tree, folded)) card.id,
      ],
  ];
  for (final lane in lanes) {
    if (lane.contains(id)) return lane;
  }
  return [for (final lane in lanes) ...lane];
}

/// How deep each of [cards] sits under the others: 0 for one whose parent is
/// not among them.
Map<String, int> overviewDepthsIn(List<OverviewCard> cards) {
  final parentOf = {for (final card in cards) card.id: card.parentId};
  int depthOf(String id) {
    var depth = 0;
    final seen = {id};
    for (
      var parent = parentOf[id];
      parent != null && parentOf.containsKey(parent) && seen.add(parent);
      parent = parentOf[parent]
    ) {
      depth++;
    }
    return depth;
  }

  return {for (final card in cards) card.id: depthOf(card.id)};
}

/// **The Overview, hybrid**: a slim strip on top, the lane chips under it
/// — on a phone, one row of both — then every family in its fixed place, lane by lane. What waits on you is
/// in the waiting drawer, over the board, so opening it moves nothing.
class OverviewHybrid extends ConsumerStatefulWidget {
  const OverviewHybrid({
    required this.onOpen,
    this.onEdit,
    this.onTerminal,
    this.questionControllerOf,
    this.onAnswered,
    super.key,
  });

  /// See [OverviewQueueCard.onAnswered].
  final ValueChanged<OverviewCard>? onAnswered;

  /// A card was tapped: peek it.
  final ValueChanged<OverviewCard> onOpen;

  /// See [OverviewQueueCard.onEdit] and [OverviewQueueCard.onTerminal].
  final ValueChanged<OverviewCard>? onEdit;
  final ValueChanged<OverviewCard>? onTerminal;

  /// The keyboard's hold on each waiting question, by session id.
  final QuestionPromptController Function(String id)? questionControllerOf;

  @override
  ConsumerState<OverviewHybrid> createState() => _OverviewHybridState();
}

class _OverviewHybridState extends ConsumerState<OverviewHybrid> {
  /// Each family's key, so a family keeps its state wherever it is drawn.
  final _treeKeys = <String, GlobalKey>{};

  /// Each lane's header, for its chip to scroll to and to light the chip of
  /// the lane on screen.
  final _laneKeys = <String, GlobalKey>{};
  final _scroll = ScrollController();
  final _viewport = GlobalKey();
  String? _laneOnScreen;
  var _lanes = const <String>[];

  /// The most families across.
  static const _maxAcross = 3;

  @override
  void initState() {
    super.initState();
    // A session asked for before the board was up, from quick open.
    if (ref.read(overviewRevealProvider) case final asked?) _reveal(asked);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Brings [asked] into view: its family unfolded, it selected — or peeked,
  /// while a peek is open — and scrolled to.
  void _reveal(({String id, int ask}) asked) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final id = asked.id;
      final forest = ref.read(overviewForestProvider);
      ref
          .read(overviewFoldedParentsProvider.notifier)
          .open(overviewAncestorsIn(forest, id));
      final focus = ref.read(overviewFocusProvider);
      final card = overviewCardOf(ref.read(overviewBoardProvider), id);
      if (card != null && focus.peeked != null && focus.peeked != id) {
        widget.onOpen(card);
      } else {
        ref.read(overviewFocusProvider.notifier).select(id);
      }
      ref.read(overviewRevealProvider.notifier).done(asked.ask);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollTo(id);
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// Scrolls [id]'s row, or its family, into view.
  void _scrollTo(String id) {
    final root = overviewFamilyOf(ref.read(overviewForestProvider), id);
    final family = _treeKeys[root?.tree.card.id]?.currentContext;
    if (family is! Element) return;
    Element? row;
    if (root!.tree.card.id != id) {
      final key = ValueKey('overview-tree-node:$id');
      void visit(Element element) {
        if (row != null) return;
        if (element.widget.key == key) {
          row = element;
          return;
        }
        element.visitChildElements(visit);
      }

      family.visitChildElements(visit);
    }
    unawaited(
      Scrollable.ensureVisible(
        row ?? family,
        duration: Motion.of(context).base,
        alignment: 0.5,
      ),
    );
  }

  /// Lights the chip of the last lane whose header has reached the top.
  void _trackLane() {
    final view = _viewport.currentContext?.findRenderObject();
    if (view is! RenderBox || !view.hasSize) return;
    String? on;
    for (final key in _lanes) {
      final box = _laneKeys[key]?.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final top = box.localToGlobal(Offset.zero, ancestor: view).dy;
      if (on == null || top <= Insets.xl) on = key;
    }
    if (on != _laneOnScreen && mounted) setState(() => _laneOnScreen = on);
  }

  void _goToLane(String key) {
    final target = _laneKeys[key]?.currentContext;
    if (target == null) return;
    setState(() => _laneOnScreen = key);
    unawaited(
      Scrollable.ensureVisible(target, duration: Motion.of(context).base),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(overviewRevealProvider, (_, asked) {
      if (asked != null) _reveal(asked);
    });
    final board = ref.watch(overviewBoardProvider);
    final statusOf = ref.read(sessionStatusLookupProvider);
    for (final lane in board.lanes) {
      for (final card in lane.cards(BoardColumn.needsYou)) {
        ref.watch(agentSessionStatusProvider(card.id));
      }
    }
    final folded = ref.watch(overviewFoldedParentsProvider);
    final forest = ref.watch(overviewForestProvider);
    final sections = overviewSectionsOf(
      board,
      forest,
      waitingSince: (id) => statusOf(id)?.waitingSince,
      folded: folded,
    );
    final hasFilters = ref.watch(overviewActiveFiltersProvider).isNotEmpty;
    final pinned = watchOverviewPinned(ref);
    final pinnedIds = {for (final card in pinned) card.id};
    final allStates = ref.watch(
      overviewPrefsProvider.select((p) => p.filter.allStates),
    );
    final drawer = ref.watch(overviewDrawerProvider.select((d) => d.open));
    final more = ref.watch(overviewMoreProvider);
    final highlight = ref.watch(overviewHighlightProvider);
    final theme = Theme.of(context);
    final muted = UiDensity.of(context).muted(theme);
    final onOpen = widget.onOpen;
    _lanes = [for (final (lane, _) in forest.lanes) lane.key];
    _laneKeys.removeWhere((key, _) => !_lanes.contains(key));
    final searchSheet = ref.watch(overviewSearchSheetProvider);
    final fresh = [
      for (final card in overviewForestMembers(forest))
        if (watchOverviewNewCount(ref, card) > 0) card,
    ].length;
    WidgetsBinding.instance.addPostFrameCallback((_) => _trackLane());

    // The families New or Pinned leave out: they dim in place. Read here,
    // in build, where a watch is kept.
    bool lit(OverviewTreeNode node) => switch (highlight) {
      OverviewHighlight.none => true,
      OverviewHighlight.pinned => node.drawn.any(
        (c) => pinnedIds.contains(c.id),
      ),
      OverviewHighlight.fresh => node.drawn.any(
        (c) => watchOverviewNewCount(ref, c) > 0,
      ),
    };
    // A search dims the families with no match; a match never moves.
    final searching = ref.watch(overviewSearchProvider.select((s) => s.active));
    final matches = searching
        ? {for (final card in watchOverviewSearchMatches(ref, forest)) card.id}
        : null;
    final dimmed = {
      for (final (_, trees) in forest.lanes)
        for (final tree in trees)
          if (!lit(tree) ||
              (matches != null &&
                  !tree.drawn.any((c) => matches.contains(c.id))))
            tree.card.id,
    };

    return LayoutBuilder(
      builder: (context, box) {
        final scaler = MediaQuery.textScalerOf(context);
        // A phone draws the same families, its avatars a step smaller.
        final phone = box.maxWidth < WidthClass.mediumMin;
        final wide =
            box.maxWidth >=
            WidthClass.scaleBreakpoint(WidthClass.expandedMin, scaler);
        final gutter = phone ? Insets.sm : Insets.xl;
        // Between families: a list's step on a phone.
        final gap = phone ? Insets.sm : Insets.md;
        final inner = box.maxWidth - gutter * 2;
        final cell = WidthClass.scaleBreakpoint(Chrome.familyCellMin, scaler);
        final across = ((inner + Insets.md) / (cell + Insets.md)).floor().clamp(
          1,
          _maxAcross,
        );
        final drawn = <String>{};
        Widget tree(OverviewTreeNode node, String laneKey, List<String> roots) {
          final id = node.card.id;
          final family = OverviewFamilyTree(
            // A global key twice in a frame throws; a second draw goes without.
            key: drawn.add(id)
                ? _treeKeys.putIfAbsent(id, GlobalKey.new)
                : ValueKey('overview-tree:$id'),
            node: node,
            onOpen: onOpen,
            compact: phone,
            wide: wide,
            laneKey: laneKey,
            laneRoots: roots,
            matches: matches,
          );
          final shown = AnimatedOpacity(
            opacity: dimmed.contains(id) ? StateLayers.dimmedOpacity : 1,
            duration: Motion.of(context).fast,
            child: family,
          );
          return DragTarget<String>(
            onWillAcceptWithDetails: (drag) =>
                drag.data != id && roots.contains(drag.data),
            onAcceptWithDetails: (drag) => ref
                .read(overviewFamilyOrderProvider.notifier)
                .move(laneKey, roots, drag.data, roots.indexOf(id)),
            builder: (context, over, _) => Container(
              foregroundDecoration: over.isEmpty
                  ? null
                  : BoxDecoration(
                      color: StateLayers.dropTarget(theme.colorScheme),
                      borderRadius: BorderRadius.circular(Radii.lg),
                    ),
              child: shown,
            ),
          );
        }

        final work = Column(
          key: const ValueKey('overview-work'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (forest.lanes.isEmpty)
              Text(
                allStates
                    ? 'Nothing is running or ready right now.'
                    : 'Nothing here right now.',
                key: const ValueKey('overview-none-at-work'),
                style: muted,
              )
            else
              for (final (lane, trees) in forest.lanes) ...[
                OverviewLaneHeader(
                  key: _laneKeys.putIfAbsent(lane.key, GlobalKey.new),
                  lane: lane,
                  trees: trees,
                ),
                ..._grid(
                  [
                    for (final node in trees)
                      tree(node, lane.key, [for (final t in trees) t.card.id]),
                  ],
                  across,
                  gap: gap,
                ),
              ],
          ],
        );
        _treeKeys.removeWhere((id, _) => !drawn.contains(id));

        final list = SingleChildScrollView(
          key: const ValueKey('overview-hybrid'),
          controller: _scroll,
          // A phone's first lane header sits a compact step under the strip.
          padding: EdgeInsets.fromLTRB(
            gutter,
            phone ? Insets.xs : Insets.sm,
            gutter,
            Insets.xxl,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (more) ...[
                const OverviewHeartbeat(today: false),
                const OverviewGlances(),
                const OverviewWaitingLane(),
                const OverviewPipelineLane(),
                const SizedBox(height: Insets.md),
              ],
              if (hasFilters) ...[
                const OverviewActiveFilterChips(),
                const SizedBox(height: Insets.md),
              ],
              if (pinned.isNotEmpty) ...[
                OverviewPinnedStrip(onOpen: onOpen),
                const SizedBox(height: Insets.lg),
              ],
              work,
              // The phone's Dashboard took Sessions' tab; the list is a tap
              // away from here as well as from More.
              if (PhoneTabsScope.contains(context))
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    key: const ValueKey('overview-all-sessions'),
                    onPressed: () => ref
                        .read(phoneShellRouterProvider)
                        .current
                        ?.showMore(PhoneMoreEntry.sessions),
                    icon: const Icon(AppIcons.chatCircleDots),
                    label: const Text('All sessions'),
                  ),
                ),
            ],
          ),
        );

        final waiting = OverviewWaitingDrawer(
          queue: sections.queue,
          forest: forest,
          onOpen: onOpen,
          sheet: phone,
          onEdit: widget.onEdit,
          onTerminal: widget.onTerminal,
          onAnswered: widget.onAnswered,
          questionControllerOf: widget.questionControllerOf,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (phone)
              // Counts and lanes in one row, a compact step under the header.
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Insets.sm,
                  Insets.xs,
                  Insets.sm,
                  0,
                ),
                child: OverviewPhoneStrip(
                  waiting: sections.queue.length,
                  fresh: fresh,
                  lanes: forest.lanes,
                  onScreen: _laneOnScreen,
                  onLane: _goToLane,
                ),
              )
            else
              Padding(
                padding: EdgeInsets.fromLTRB(gutter, Insets.md, gutter, 0),
                child: OverviewTopStrip(
                  waiting: sections.queue.length,
                  queue: sections.queue,
                ),
              ),
            if (forest.lanes.isNotEmpty && !phone)
              Padding(
                padding: EdgeInsets.fromLTRB(
                  gutter,
                  Insets.sm,
                  gutter,
                  Insets.xs,
                ),
                child: OverviewLaneChips(
                  lanes: forest.lanes,
                  onScreen: _laneOnScreen,
                  onTap: _goToLane,
                ),
              ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, area) => Stack(
                  key: _viewport,
                  children: [
                    Positioned.fill(
                      child: NotificationListener<ScrollNotification>(
                        onNotification: (note) {
                          if (note.metrics.axis == Axis.vertical) {
                            _trackLane();
                          }
                          return false;
                        },
                        child: list,
                      ),
                    ),
                    if (searchSheet && phone)
                      Positioned.fill(
                        child: OverviewSearchSheet(queue: sections.queue),
                      )
                    else if (drawer && phone)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        height: area.maxHeight * Chrome.waitingSheetShare,
                        child: waiting,
                      )
                    else if (drawer)
                      Positioned(
                        top: Insets.xs,
                        right: Insets.sm,
                        bottom: Insets.sm,
                        width: Chrome.waitingDrawerWidth.clamp(
                          0.0,
                          area.maxWidth - Insets.sm * 2,
                        ),
                        child: waiting,
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// [cells] — whole families — in rows of [across], each family keeping its
  /// own height, from the top, [gap] apart.
  static List<Widget> _grid(
    List<Widget> cells,
    int across, {
    required double gap,
  }) => [
    for (var start = 0; start < cells.length; start += across)
      Padding(
        padding: EdgeInsets.only(bottom: gap),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = start; i < start + across; i++) ...[
              if (i > start) SizedBox(width: gap),
              Expanded(
                child: i < cells.length ? cells[i] : const SizedBox.shrink(),
              ),
            ],
          ],
        ),
      ),
  ];
}
