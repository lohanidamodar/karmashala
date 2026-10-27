import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart' show EyebrowLabel;
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/widgets/adaptive_modal.dart';
import '../../explorer/application/agent_states.dart';
import '../../sessions/presentation/prompt_cards/question_prompt_card.dart';
import '../application/overview_board.dart';
import '../application/overview_drawer.dart';
import '../application/overview_family_order.dart';
import '../application/overview_reads.dart';
import '../application/overview_search.dart';
import '../application/overview_tree.dart';
import 'overview_card_links.dart';
import 'overview_card_parts.dart';
import 'overview_counters.dart';
import 'overview_done_card.dart';
import 'overview_queue_card.dart';
import 'overview_session_parts.dart';

/// **The dashboard's slim strip**: Today's counts, the search field, New and
/// Pinned (which dim the rest), Waiting N (the drawer) and More (the
/// heartbeat, glances and lanes under it). Narrow, the controls wrap under
/// the counts. On a [phone] the bottom bar holds search, New, Pinned and
/// Waiting, so the strip keeps the counts and More.
class OverviewTopStrip extends ConsumerWidget {
  const OverviewTopStrip({
    required this.waiting,
    this.queue = const [],
    this.phone = false,
    super.key,
  });

  /// How many wait on the owner: the Waiting button's count.
  final int waiting;

  final bool phone;

  /// What waits on the owner, in the drawer's order: the search lists it
  /// first while it is empty.
  final List<OverviewCard> queue;

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
        final moreToggle = OverviewStripToggle(
          key: const ValueKey('overview-more-toggle'),
          label: 'Activity',
          icon: more ? AppIcons.caretDown : AppIcons.caretRight,
          selected: more,
          onTap: ref.read(overviewMoreProvider.notifier).toggle,
        );
        if (phone) {
          return Row(
            key: const ValueKey('overview-strip'),
            children: [
              const Expanded(child: counts),
              const SizedBox(width: Insets.xs),
              moreToggle,
            ],
          );
        }
        final controls = <Widget>[
          SizedBox(
            width: searchWidth,
            child: OverviewSearchBox(queue: queue),
          ),
          OverviewStripToggle(
            key: const ValueKey('overview-strip-new'),
            label: 'New',
            selected: highlight == OverviewHighlight.fresh,
            onTap: () => lit.toggle(OverviewHighlight.fresh),
          ),
          OverviewStripToggle(
            key: const ValueKey('overview-strip-pinned'),
            label: 'Pinned',
            icon: AppIcons.pushPin,
            selected: highlight == OverviewHighlight.pinned,
            onTap: () => lit.toggle(OverviewHighlight.pinned),
          ),
          OverviewStripToggle(
            key: const ValueKey('overview-waiting-toggle'),
            label: 'Waiting $waiting',
            selected: drawer,
            hot: waiting > 0,
            onTap: ref.read(overviewDrawerProvider.notifier).toggle,
          ),
          moreToggle,
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
class OverviewStripToggle extends StatelessWidget {
  const OverviewStripToggle({
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
    this.focusNodeOf,
    super.key,
  });

  final List<(OverviewLane, List<OverviewTreeNode>)> lanes;
  final String? onScreen;
  final ValueChanged<String> onTap;

  /// Each chip's focus, by lane key, so the phone's Lanes can reach one.
  final FocusNode Function(String lane)? focusNodeOf;

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
            focusNode: focusNodeOf?.call(lane.key),
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
    this.focusNode,
  });

  final OverviewLane lane;
  final List<OverviewTreeNode> trees;
  final bool selected;
  final VoidCallback onTap;
  final FocusNode? focusNode;

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
          focusNode: focusNode,
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
                child: Text('${archived.length} archived today'),
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

/// [forest]'s sessions whose title or latest line match the search, folded
/// and done ones included, in drawn order; empty while nothing is typed.
List<OverviewCard> watchOverviewSearchMatches(
  WidgetRef ref,
  OverviewForest forest,
) {
  final query = ref.watch(overviewSearchProvider.select((s) => s.query));
  if (query.trim().isEmpty) return const [];
  return overviewSearchMatchesIn(forest, query, (card) {
    final said = ref.watch(overviewLastAnswerProvider(card.id)).value?.text;
    return [
      if (said != null) overviewPlain(said),
      watchOverviewLine(ref, card),
    ].join(' ');
  });
}

/// **The dashboard's search**: `/` focuses it; typing dims what does not
/// match; ↑ and ↓ step through the matches, Enter goes to one, Esc clears.
/// Empty and focused, it lists what needs you, then what is new.
class OverviewSearchBox extends ConsumerStatefulWidget {
  const OverviewSearchBox({required this.queue, super.key});

  final List<OverviewCard> queue;

  @override
  ConsumerState<OverviewSearchBox> createState() => _OverviewSearchBoxState();
}

class _OverviewSearchBoxState extends ConsumerState<OverviewSearchBox> {
  final _controller = TextEditingController();
  final _focus = FocusNode(debugLabel: 'overview-search');
  final _portal = OverlayPortalController();
  final _link = LayerLink();

  /// What the keys step through: the matches, or the list under an empty
  /// field.
  var _ids = const <String>[];

  /// The query [_ids] were drawn for; a key typed before the next frame
  /// waits for it.
  String? _idsFor;

  @override
  void initState() {
    super.initState();
    _controller.text = ref.read(overviewSearchProvider).query;
    _focus.addListener(_focusChanged);
  }

  @override
  void dispose() {
    _focus.removeListener(_focusChanged);
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _focusChanged() {
    if (!mounted) return;
    _focus.hasFocus ? _portal.show() : _portal.hide();
    setState(() {});
  }

  OverviewSearchController get _search =>
      ref.read(overviewSearchProvider.notifier);

  void _reveal(String id) =>
      ref.read(overviewRevealProvider.notifier).reveal(id);

  /// Hands the keys back to the board.
  void _leave() =>
      _focus.unfocus(disposition: UnfocusDisposition.previouslyFocusedChild);

  void _go([String? id]) {
    final to =
        id ?? ref.read(overviewSearchProvider).current ?? _ids.firstOrNull;
    if (to == null) return;
    _reveal(to);
    _leave();
  }

  /// Runs [then] on matches drawn for what is typed now.
  void _drawn(VoidCallback then) {
    if (_idsFor == ref.read(overviewSearchProvider).query) {
      then();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) then();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown || LogicalKeyboardKey.arrowUp:
        final step = event.logicalKey == LogicalKeyboardKey.arrowDown ? 1 : -1;
        _drawn(() {
          if (_search.step(_ids, step) case final id?) _reveal(id);
        });
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter:
        if (event is KeyDownEvent) _drawn(_go);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        if (event is KeyDownEvent) {
          _search.clear();
          _controller.clear();
          _leave();
        }
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(overviewSearchProvider.select((s) => s.focusAsks), (_, _) {
      _focus.requestFocus();
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _controller.text.length,
      );
    });
    ref.listen(overviewSearchProvider.select((s) => s.query), (_, query) {
      if (_controller.text != query) _controller.text = query;
    });
    final search = ref.watch(overviewSearchProvider);
    final forest = ref.watch(overviewForestProvider);
    final List<(String, List<OverviewCard>)> sections;
    _idsFor = search.query;
    if (search.active) {
      final matches = watchOverviewSearchMatches(ref, forest);
      sections = const [];
      _ids = [for (final card in matches) card.id];
    } else if (_focus.hasFocus) {
      sections = watchOverviewSearchHints(ref, forest, widget.queue);
      _ids = [
        for (final (_, cards) in sections)
          for (final card in cards) card.id,
      ];
    } else {
      sections = const [];
      _ids = const [];
    }
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: (_) => sections.isEmpty
          ? const SizedBox.shrink()
          : CompositedTransformFollower(
              link: _link,
              showWhenUnlinked: false,
              targetAnchor: Alignment.bottomLeft,
              offset: const Offset(0, Insets.xs),
              child: Align(
                alignment: AlignmentDirectional.topStart,
                child: TextFieldTapRegion(
                  child: OverviewSearchResults(
                    sections: sections,
                    current: search.current,
                    onPick: _go,
                  ),
                ),
              ),
            ),
      child: CompositedTransformTarget(
        link: _link,
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: _onKey,
          child: SearchField(
            key: const ValueKey('overview-search'),
            controller: _controller,
            focusNode: _focus,
            clearOnEscape: false,
            decoration: compactSearchDecoration(hintText: 'Search sessions'),
            onChanged: _search.type,
          ),
        ),
      ),
    );
  }
}

/// What an empty search lists: what needs you ([queue]), then what is new.
List<(String, List<OverviewCard>)> watchOverviewSearchHints(
  WidgetRef ref,
  OverviewForest forest,
  List<OverviewCard> queue,
) {
  final asks = {for (final card in queue) card.id};
  final fresh = [
    for (final card in overviewForestMembers(forest))
      if (!asks.contains(card.id) && watchOverviewNewCount(ref, card) > 0) card,
  ];
  return [
    if (queue.isNotEmpty) ('Needs you', queue),
    if (fresh.isNotEmpty) ('New', fresh),
  ];
}

/// What a search lists: each section's sessions, the one the keys are on
/// lit. A dropdown under the field, or on a phone's [sheet] a plain list.
class OverviewSearchResults extends StatelessWidget {
  const OverviewSearchResults({
    required this.sections,
    required this.current,
    required this.onPick,
    this.sheet = false,
    super.key,
  });

  final List<(String, List<OverviewCard>)> sections;
  final String? current;
  final ValueChanged<String> onPick;
  final bool sheet;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final density = UiDensity.of(context);
    final screen = MediaQuery.sizeOf(context);
    final rows = [
      for (final (title, cards) in sections) ...[
        EyebrowLabel(
          title,
          padding: const EdgeInsets.fromLTRB(
            Insets.md,
            Insets.xs,
            Insets.md,
            Insets.xxs,
          ),
        ),
        for (final card in cards)
          InkWell(
            key: ValueKey('overview-search-hint:$title:${card.id}'),
            onTap: () => onPick(card.id),
            child: Container(
              color: card.id == current
                  ? StateLayers.selected(scheme)
                  : Colors.transparent,
              constraints: BoxConstraints(
                minHeight: density.isTouch ? Touch.target : Chrome.menuRow,
              ),
              padding: const EdgeInsets.symmetric(horizontal: Insets.md),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      card.entry.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  const SizedBox(width: Insets.sm),
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: AlignmentDirectional.centerEnd,
                      child: OverviewStatePill(card: card),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    ];
    if (sheet) {
      return ListView(
        key: const ValueKey('overview-search-sheet-list'),
        padding: const EdgeInsets.symmetric(vertical: Insets.xs),
        children: rows,
      );
    }
    final width = WidthClass.scaleBreakpoint(
      Chrome.waitingDrawerWidth,
      MediaQuery.textScalerOf(context),
    ).clamp(0.0, screen.width - Insets.lg * 2);
    return Material(
      key: const ValueKey('overview-search-list'),
      elevation: Elevations.popup,
      color: scheme.surfaceContainerHigh,
      shadowColor: scheme.shadow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: width,
          minWidth: width,
          maxHeight: screen.height * Chrome.waitingSheetShare / 2,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: Insets.xs),
          children: rows,
        ),
      ),
    );
  }
}
