import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_projects/karmashala_projects.dart' show Project;
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/rows.dart' show compactAge;
import 'package:karmashala_ui/tokens.dart';

import '../../../app/shell/workbench_tabs.dart' show openProjectTab;
import '../../../core/util/clock_provider.dart';
import '../../explorer/application/agent_states.dart';
import '../../explorer/presentation/explorer_project_row.dart'
    show ProjectRowActions, showProjectMenu;
import '../../projects/application/projects_controller.dart';
import '../../projects/presentation/edit_project_dialog.dart';
import '../application/overview_board.dart';
import '../application/overview_drawer.dart';
import '../application/overview_prefs.dart';
import '../application/overview_providers.dart';
import '../application/overview_shown.dart';
import '../application/overview_tree.dart';
import 'overview_cards.dart' show overviewCardEdge;
import 'overview_counters.dart' show overviewCompactChipHeight;
import 'overview_done_card.dart';
import 'overview_session_parts.dart';
import 'overview_tree.dart' show showOverviewFamilyMenu;

/// The project behind tile [key], or null for the tile of sessions in none
/// and for a project this app no longer lists.
Project? overviewProjectOf(WidgetRef ref, String key) => ref
    .watch(projectsControllerProvider)
    .where((project) => project.id == key)
    .firstOrNull;

/// Opens [project]'s page: what "Open project" does — its name on a tile, O
/// on the board, Enter on a project the search found.
void openOverviewProject(
  BuildContext context,
  WidgetRef ref,
  Project project,
) => openProjectTab(ref, project.id);

/// Starts a session in [project] as its row's + does: at once with the
/// defaults, or through the dialog when a piece is missing.
void newOverviewProjectSession(
  BuildContext context,
  WidgetRef ref,
  Project project,
) => unawaited(ProjectRowActions(ref, context, project).startWithDefaults());

/// Opens [project]'s edit dialog.
void editOverviewProject(BuildContext context, Project project) =>
    unawaited(EditProjectDialog.show(context, project));

/// **One project on the dashboard**: its name, which opens it, what its
/// sessions are doing in numbers, + for a new session and ⋯ for the
/// project's menu; then its families in their fixed order — a card for one
/// that needs you, runs or is new, one line for one that is finished and
/// seen. It folds to its header, and never moves when a session changes.
class OverviewProjectTile extends ConsumerStatefulWidget {
  const OverviewProjectTile({
    required this.tile,
    required this.lines,
    required this.drawn,
    required this.onFold,
    this.folded = false,
    this.framed = true,
    this.tag,
    this.keep = const {},
    super.key,
  });

  final OverviewTile tile;

  /// The roots of the families drawn as one line.
  final Set<String> lines;

  /// Each family as the board draws it — a card, or a line for one in
  /// [lines] — by its root. Built by the board, which holds each family's
  /// key, so a family keeps its state whatever its tile does.
  final Map<String, Widget> drawn;

  /// Whether only the header is drawn, and the header's fold asking to
  /// change that.
  final bool folded;
  final ValueChanged<bool> onFold;

  /// Whether it has an edge of its own; a phone's has none, to keep the
  /// cards the screen's width.
  final bool framed;

  /// A word after the name: the project's context, where the board does not
  /// group by it.
  final String? tag;

  /// Roots never folded behind "Show N more": the selection and what a
  /// search matched.
  final Set<String> keep;

  /// The lines drawn before the older ones fold behind "Show N more".
  static const shownLines = 5;

  @override
  ConsumerState<OverviewProjectTile> createState() =>
      _OverviewProjectTileState();
}

class _OverviewProjectTileState extends ConsumerState<OverviewProjectTile> {
  var _showAll = false;

  @override
  Widget build(BuildContext context) {
    final tile = widget.tile;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final project = overviewProjectOf(ref, tile.key);
    final cards = [for (final tree in tile.trees) ...tree.drawn];
    final statuses = [
      for (final card in cards) overviewStatusWith(ref.watch, card),
    ];
    int count(OverviewStatus status) =>
        statuses.where((s) => s == status).length;
    final needs = count(OverviewStatus.needsYou);
    final running = count(OverviewStatus.running);

    // The five lines last active stay; older ones fold behind one row.
    final lines = [
      for (final tree in tile.trees)
        if (widget.lines.contains(tree.card.id)) tree,
    ];
    final recent = [...lines]
      ..sort(
        (a, b) => b.card.entry.activityAt.compareTo(a.card.entry.activityAt),
      );
    final selected = ref.watch(overviewFocusProvider.select((f) => f.selected));
    final hidden = _showAll
        ? const <String>{}
        : {
            for (final tree in recent.skip(OverviewProjectTile.shownLines))
              if (!widget.keep.contains(tree.card.id) &&
                  tree.card.id != selected)
                tree.card.id,
          };
    final long = lines.length > OverviewProjectTile.shownLines;

    final edge = needs > 0
        ? overviewCardEdge(context, AgentState.needsYou)
        : running > 0
        ? SemanticColors.of(
            context,
          ).working.withValues(alpha: SemanticColors.surfaceEdgeAlpha)
        : scheme.outlineVariant;
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _TileHeader(
          tile: tile,
          project: project,
          tag: widget.tag,
          folded: widget.folded,
          statuses: statuses,
          asks: tile.trees.fold(0, (sum, t) => sum + overviewWaitingIn(t)),
          done: [
            for (final tree in tile.trees)
              if (tree.card.state == AgentState.ended &&
                  overviewFamilyToArchive(tree).isNotEmpty)
                tree,
          ],
          onFold: () => widget.onFold(!widget.folded),
        ),
        if (tile.trees.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.sm,
              vertical: Insets.xs,
            ),
            child: Text(
              'No session here',
              key: ValueKey('overview-tile-empty:${tile.key}'),
              style: UiDensity.of(context).muted(theme),
            ),
          )
        else if (!widget.folded) ...[
          for (final tree in tile.trees)
            if (!hidden.contains(tree.card.id))
              Padding(
                padding: EdgeInsets.only(
                  top: widget.lines.contains(tree.card.id)
                      ? Insets.xxs
                      : Insets.sm,
                ),
                child: widget.drawn[tree.card.id],
              ),
          if (long && (hidden.isNotEmpty || _showAll))
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                key: ValueKey('overview-tile-more:${tile.key}'),
                style: UiDensity.of(context).compactButton,
                onPressed: () => setState(() => _showAll = !_showAll),
                child: Text(
                  _showAll ? 'Show fewer' : 'Show ${hidden.length} more',
                ),
              ),
            ),
        ],
      ],
    );
    if (!widget.framed) {
      return KeyedSubtree(
        key: ValueKey('overview-tile:${tile.key}'),
        child: body,
      );
    }
    return Container(
      key: ValueKey('overview-tile:${tile.key}'),
      padding: const EdgeInsets.fromLTRB(
        Insets.sm,
        Insets.xs,
        Insets.sm,
        Insets.sm,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: edge),
      ),
      child: body,
    );
  }
}

/// A tile's header: the fold, the project's name — which opens it — its
/// counts, and + and ⋯.
class _TileHeader extends ConsumerWidget {
  const _TileHeader({
    required this.tile,
    required this.project,
    required this.tag,
    required this.folded,
    required this.statuses,
    required this.asks,
    required this.done,
    required this.onFold,
  });

  final OverviewTile tile;
  final Project? project;
  final String? tag;
  final bool folded;
  final List<OverviewStatus> statuses;

  /// How many of its sessions ask the owner something themselves.
  final int asks;

  /// Its ended families, for "Archive done".
  final List<OverviewTreeNode> done;
  final VoidCallback onFold;

  static const _archiveDone = 'archive-done';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    int count(OverviewStatus status) =>
        statuses.where((s) => s == status).length;
    final parts = <(String, Color?)>[
      if (count(OverviewStatus.needsYou) case final n when n > 0)
        ('$n ${n == 1 ? 'needs' : 'need'} you', semantic.attention),
      if (count(OverviewStatus.running) case final n when n > 0)
        ('$n running', semantic.working),
      if (count(OverviewStatus.fresh) case final n when n > 0)
        ('$n new', scheme.primary),
    ];
    final name = theme.textTheme.titleSmall?.copyWith(
      fontWeight: FontWeight.w600,
    );
    final title = Text(
      tile.label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: name,
    );
    final sessions = statuses.length;
    return LayoutBuilder(
      builder: (context, box) => _row(
        context,
        ref,
        title: title,
        parts: parts,
        sessions: sessions,
        // The counts give way to the name, never the other way round.
        countsWidth: box.maxWidth * _countsShare,
      ),
    );
  }

  /// The most of the header its counts take.
  static const _countsShare = 0.4;

  Widget _row(
    BuildContext context,
    WidgetRef ref, {
    required Widget title,
    required List<(String, Color?)> parts,
    required int sessions,
    required double countsWidth,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final density = UiDensity.of(context);
    final semantic = SemanticColors.of(context);
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final project = this.project;
    final radius = BorderRadius.circular(Radii.sm);
    final height = overviewCompactChipHeight(context);
    return Row(
      children: [
        Semantics(
          button: true,
          expanded: !folded,
          label: [
            tile.label,
            '$sessions ${sessions == 1 ? 'session' : 'sessions'}',
            for (final (text, _) in parts) text,
          ].join(', '),
          hint: folded ? 'Show the project' : 'Fold the project',
          excludeSemantics: true,
          child: Tooltip(
            message: folded ? 'Show ${tile.label}' : 'Fold ${tile.label}',
            child: InkWell(
              key: ValueKey('overview-lane-fold:${tile.key}'),
              borderRadius: radius,
              onTap: onFold,
              child: SizedBox(
                width: height,
                height: height,
                child: Icon(
                  folded ? AppIcons.caretRight : AppIcons.caretDown,
                  size: density.iconSmall,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: Row(
            children: [
              Flexible(
                flex: 3,
                child: project == null
                    ? title
                    : Tooltip(
                        message: 'Open ${tile.label} (O)',
                        child: InkWell(
                          key: ValueKey('overview-tile-open:${tile.key}'),
                          borderRadius: radius,
                          onTap: () =>
                              openOverviewProject(context, ref, project),
                          child: ConstrainedBox(
                            constraints: BoxConstraints(minHeight: height),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: Insets.xs,
                              ),
                              child: Align(
                                alignment: AlignmentDirectional.centerStart,
                                widthFactor: 1,
                                child: title,
                              ),
                            ),
                          ),
                        ),
                      ),
              ),
              if (tag case final tag?) ...[
                const SizedBox(width: Insets.xs),
                Flexible(
                  child: Text(
                    tag,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: muted,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: Insets.sm),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: countsWidth),
          // Folded, what waits inside is what the counts say.
          child: folded && asks > 0
              ? Text(
                  '$asks waiting',
                  key: ValueKey('overview-lane-folded-asks:${tile.key}'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: semantic.attention,
                    fontWeight: FontWeight.w700,
                  ),
                )
              : Text.rich(
                  TextSpan(
                    children: [
                      for (final (i, (text, color)) in parts.indexed) ...[
                        if (i > 0) const TextSpan(text: ' · '),
                        TextSpan(
                          text: text,
                          style: TextStyle(
                            color: color,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                      if (parts.isEmpty) TextSpan(text: '$sessions'),
                    ],
                  ),
                  key: ValueKey('overview-tile-counts:${tile.key}'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                  style: muted,
                ),
        ),
        if (project != null) ...[
          IconButton(
            key: ValueKey('overview-tile-new:${tile.key}'),
            tooltip: 'New session in ${tile.label} (C)',
            visualDensity: density.controlDensity,
            constraints: density.iconConstraints(Chrome.control),
            iconSize: density.iconSize(Chrome.iconSmall),
            onPressed: () => newOverviewProjectSession(context, ref, project),
            icon: const Icon(AppIcons.plus),
          ),
          Builder(
            builder: (button) => IconButton(
              key: ValueKey('overview-tile-menu:${tile.key}'),
              tooltip: 'Project actions',
              visualDensity: density.controlDensity,
              constraints: density.iconConstraints(Chrome.control),
              iconSize: density.iconSize(Chrome.iconSmall),
              onPressed: () => showProjectMenu(
                button,
                ref,
                project,
                extras: [
                  if (done.isNotEmpty)
                    DesktopMenuItem(
                      value: _archiveDone,
                      label: 'Archive done · ${done.length}',
                      icon: AppIcons.tray,
                    ),
                ],
                onExtra: (_) {
                  for (final tree in done) {
                    unawaited(archiveFamilyFromDashboard(context, ref, tree));
                  }
                },
              ),
              icon: const Icon(AppIcons.dotsThree),
            ),
          ),
        ] else if (done.isNotEmpty)
          IconButton(
            key: ValueKey('overview-lane-archive:${tile.key}'),
            tooltip: 'Archive done · ${done.length}',
            visualDensity: density.controlDensity,
            constraints: density.iconConstraints(Chrome.control),
            iconSize: density.iconSize(Chrome.iconSmall),
            onPressed: () {
              for (final tree in done) {
                unawaited(archiveFamilyFromDashboard(context, ref, tree));
              }
            },
            icon: const Icon(AppIcons.tray),
          ),
      ],
    );
  }
}

/// **A finished, seen family as one line**: its state, its title, how many
/// sub-sessions it had, and how long ago it was last active. A tap opens
/// its chat as a card's does; a right-click or a long press, its menu.
class OverviewSessionLine extends ConsumerWidget {
  const OverviewSessionLine({
    required this.node,
    required this.onOpen,
    super.key,
  });

  final OverviewTreeNode node;
  final ValueChanged<OverviewCard> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final card = node.card;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final density = UiDensity.of(context);
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final selected = ref.watch(
      overviewFocusProvider.select((f) => f.selected == card.id),
    );
    final pinned = ref.watch(
      overviewPrefsProvider.select((p) => p.pinned.contains(card.id)),
    );
    final kids = node.descendants.length;
    final age = compactAge(
      ref.read(clockProvider).nowUtc().difference(card.entry.activityAt),
    );
    final radius = BorderRadius.circular(Radii.md);
    Future<void> menu({Offset? at}) =>
        showOverviewFamilyMenu(context, ref, node, at: at);
    // M and `.` on a selected line: its chat to type in, and its menu.
    ref.listen(overviewCardAskProvider, (_, ask) {
      if (ask == null || ask.id != card.id) return;
      switch (ask.what) {
        case OverviewCardAsk.message:
          onOpen(card);
        case OverviewCardAsk.menu:
          unawaited(menu());
        case OverviewCardAsk.stop:
          break;
      }
    });
    return Semantics(
      button: true,
      selected: selected,
      label: [
        card.entry.title,
        card.state.label,
        if (kids > 0) overviewSubSessionCount(kids),
        age,
      ].join(', '),
      hint: 'Open chat',
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: ValueKey('overview-line:${card.id}'),
          borderRadius: radius,
          onTap: () => onOpen(card),
          onLongPress: menu,
          onSecondaryTapUp: (details) => menu(at: details.globalPosition),
          child: Container(
            constraints: BoxConstraints(
              minHeight: overviewCompactChipHeight(context),
            ),
            padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
            // Always there, as a card's ring is, so selecting moves nothing.
            foregroundDecoration: BoxDecoration(
              borderRadius: radius,
              border: selected
                  ? Border.all(
                      color: scheme.primary,
                      width: StateLayers.focusRingWidth * 2,
                    )
                  : null,
            ),
            child: Row(
              children: [
                OverviewStateGlyph(
                  state: card.state,
                  size: density.iconSmall + Insets.hair,
                ),
                const SizedBox(width: Insets.sm),
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          card.entry.title,
                          key: ValueKey('overview-line-title:${card.id}'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                      if (pinned) ...[
                        const SizedBox(width: Insets.xs),
                        Icon(
                          AppIcons.pushPinFill,
                          size: density.iconSmall,
                          color: scheme.primary,
                          semanticLabel: 'Pinned',
                        ),
                      ],
                      if (kids > 0) ...[
                        const SizedBox(width: Insets.sm),
                        Text(
                          overviewSubSessionCount(kids),
                          maxLines: 1,
                          style: muted,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: Insets.sm),
                Text(age, maxLines: 1, style: muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
