import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../explorer/application/agent_state_providers.dart';
import '../../sessions/application/session_list_prefs.dart';
import '../application/overview_board.dart';
import '../application/overview_prefs.dart';
import '../application/overview_providers.dart';
import 'overview_card.dart';

/// Which of the Board's collapsed parts are open. Ephemeral: the Board opens
/// with Done and the quiet lanes folded.
@immutable
class OverviewFolds {
  const OverviewFolds({
    this.doneOpen = false,
    this.allDone = false,
    this.quietOpen = false,
  });

  final bool doneOpen;

  /// Done shows ended sessions from before today too.
  final bool allDone;
  final bool quietOpen;
}

class OverviewFoldsController extends Notifier<OverviewFolds> {
  @override
  OverviewFolds build() => const OverviewFolds();

  void toggleDone() => state = OverviewFolds(
    doneOpen: !state.doneOpen,
    allDone: state.allDone && !state.doneOpen,
    quietOpen: state.quietOpen,
  );

  void showAllDone() => state = OverviewFolds(
    doneOpen: true,
    allDone: true,
    quietOpen: state.quietOpen,
  );

  void toggleQuiet() => state = OverviewFolds(
    doneOpen: state.doneOpen,
    allDone: state.allDone,
    quietOpen: !state.quietOpen,
  );
}

final overviewFoldsProvider =
    NotifierProvider.autoDispose<OverviewFoldsController, OverviewFolds>(
      OverviewFoldsController.new,
    );

/// The Done cards [lane] draws under [folds].
List<OverviewCard> drawnDone(OverviewLane lane, OverviewFolds folds) => [
  if (folds.doneOpen) ...lane.doneToday,
  if (folds.doneOpen && folds.allDone) ...lane.doneOlder,
];

/// The card ids as drawn, lane by lane and column by column — what the arrow
/// keys move over.
List<List<List<String>>> drawnGrid(OverviewBoard board, OverviewFolds folds) =>
    [
      for (final lane in [
        ...board.lanes.where((l) => !l.isQuiet),
        if (folds.quietOpen) ...board.lanes.where((l) => l.isQuiet),
      ])
        [
          for (final column in BoardColumn.values)
            [
              for (final card
                  in column == BoardColumn.done
                      ? drawnDone(lane, folds)
                      : lane.cards(column))
                card.id,
            ],
        ],
    ];

/// The card [id] names on [board], wherever it is drawn; null when none.
OverviewCard? overviewCardOf(OverviewBoard board, String? id) {
  if (id == null) return null;
  for (final lane in board.lanes) {
    for (final column in BoardColumn.values) {
      for (final card in [
        ...lane.cards(column),
        if (column == BoardColumn.done) ...lane.doneOlder,
      ]) {
        if (card.id == id) return card;
      }
    }
  }
  return null;
}

/// Width of a lane's name, left of its columns.
const double _laneLabelWidth = 132;

/// **The Board**: a lane per project (or machine), four columns. Lanes with
/// nothing live fold into one line at the foot, Done into a count.
class OverviewBoardView extends ConsumerWidget {
  const OverviewBoardView({required this.onOpen, super.key});

  /// A card was clicked: peek it.
  final ValueChanged<OverviewCard> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final board = ref.watch(overviewBoardProvider);
    final folds = ref.watch(overviewFoldsProvider);
    final groupBy = ref.watch(overviewPrefsProvider.select((p) => p.groupBy));
    final live = [
      for (final lane in board.lanes)
        if (!lane.isQuiet) lane,
    ];
    final quiet = [
      for (final lane in board.lanes)
        if (lane.isQuiet) lane,
    ];
    final hiddenWorking = ref.watch(agentsHiddenWorkingCountProvider);
    if (board.lanes.isEmpty && hiddenWorking == 0) {
      return const PanePlaceholder(message: 'Nothing to show here.');
    }
    final noun = groupBy == OverviewGroupBy.project ? 'project' : 'machine';
    final items = <Widget>[
      _ColumnHeads(board: board),
      for (final lane in live) _LaneRow(lane: lane, onOpen: onOpen),
      if (quiet.isNotEmpty)
        _FoldLine(
          key: const ValueKey('overview-quiet-lanes'),
          label:
              '${quiet.length} quiet ${quiet.length == 1 ? noun : '${noun}s'}',
          open: folds.quietOpen,
          onTap: ref.read(overviewFoldsProvider.notifier).toggleQuiet,
        ),
      if (folds.quietOpen)
        for (final lane in quiet) _LaneRow(lane: lane, onOpen: onOpen),
      if (hiddenWorking > 0) _HiddenWorking(count: hiddenWorking),
    ];
    return ListView.builder(
      key: const ValueKey('overview-board'),
      padding: const EdgeInsets.fromLTRB(
        Insets.lg,
        Insets.sm,
        Insets.lg,
        Insets.xl,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) => items[index],
    );
  }
}

class _ColumnHeads extends StatelessWidget {
  const _ColumnHeads({required this.board});

  final OverviewBoard board;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    int count(BoardColumn column) =>
        [for (final lane in board.lanes) ...lane.cards(column)].length;
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.xs),
      child: Row(
        children: [
          const SizedBox(width: _laneLabelWidth),
          for (final column in BoardColumn.values)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
                child: Text(
                  column == BoardColumn.done
                      ? 'Done today · ${count(column)}'
                      : '${column.label} · ${count(column)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: switch (column) {
                      BoardColumn.needsYou => semantic.attention,
                      BoardColumn.working => theme.colorScheme.primary,
                      _ => theme.colorScheme.onSurfaceVariant,
                    },
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _LaneRow extends ConsumerWidget {
  const _LaneRow({required this.lane, required this.onOpen});

  final OverviewLane lane;
  final ValueChanged<OverviewCard> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final folds = ref.watch(overviewFoldsProvider);
    final density = ref.watch(overviewPrefsProvider.select((p) => p.density));
    final selected = ref.watch(overviewFocusProvider.select((f) => f.selected));
    Widget cardOf(OverviewCard card) => Padding(
      padding: const EdgeInsets.only(bottom: Insets.xs),
      child: OverviewCardTile(
        key: ValueKey('overview:${lane.key}:${card.id}'),
        card: card,
        density: density,
        selected: card.id == selected,
        onTap: () => onOpen(card),
      ),
    );
    final live = [
      for (final column in BoardColumn.values)
        if (column != BoardColumn.done) lane.cards(column).length,
    ];
    return Semantics(
      container: true,
      label: lane.label,
      child: Container(
        key: ValueKey('overview-lane:${lane.key}'),
        padding: const EdgeInsets.symmetric(vertical: Insets.sm),
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: _laneLabelWidth,
              child: Padding(
                padding: const EdgeInsets.only(right: Insets.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      lane.label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    Text(
                      live.join(' · '),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            for (final column in BoardColumn.values)
              Expanded(
                child: FocusTraversalGroup(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: column == BoardColumn.done
                          ? [
                              _FoldLine(
                                key: ValueKey('overview-done:${lane.key}'),
                                label: '${lane.doneToday.length} done today',
                                open: folds.doneOpen,
                                onTap: ref
                                    .read(overviewFoldsProvider.notifier)
                                    .toggleDone,
                              ),
                              ...drawnDone(lane, folds).map(cardOf),
                              if (folds.doneOpen &&
                                  !folds.allDone &&
                                  lane.doneOlder.isNotEmpty)
                                TextButton(
                                  onPressed: ref
                                      .read(overviewFoldsProvider.notifier)
                                      .showAllDone,
                                  child: Text(
                                    'Show all (${lane.doneOlder.length} '
                                    'older)',
                                  ),
                                ),
                            ]
                          : lane.cards(column).map(cardOf).toList(),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// "14 done today ▸" / "3 quiet projects ▸".
class _FoldLine extends StatelessWidget {
  const _FoldLine({
    required this.label,
    required this.open,
    required this.onTap,
    super.key,
  });

  final String label;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      expanded: open,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.sm),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.xs,
            vertical: Insets.xs,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              Icon(
                open ? AppIcons.caretDown : AppIcons.caretRight,
                size: 12,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "N working · Show": what Hide while working took off the Board.
class _HiddenWorking extends ConsumerWidget {
  const _HiddenWorking({required this.count});

  final int count;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Align(
    alignment: Alignment.centerLeft,
    child: TextButton.icon(
      key: const ValueKey('overview-working-hidden'),
      onPressed: () =>
          ref.read(sessionListPrefsProvider.notifier).setHideWorking(false),
      icon: const Icon(AppIcons.eyeSlash, size: 14),
      label: Text('$count working · Show'),
    ),
  );
}

/// **The narrow Overview**: one list grouped by state, with the project on
/// each card. The phone's, and a pane too narrow for four columns.
class OverviewListView extends ConsumerWidget {
  const OverviewListView({required this.onOpen, super.key});

  final ValueChanged<OverviewCard> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final board = ref.watch(overviewBoardProvider);
    final folds = ref.watch(overviewFoldsProvider);
    final density = ref.watch(overviewPrefsProvider.select((p) => p.density));
    final selected = ref.watch(overviewFocusProvider.select((f) => f.selected));
    final hiddenWorking = ref.watch(agentsHiddenWorkingCountProvider);
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final items = <Widget>[];
    for (final column in BoardColumn.values) {
      final cards = [
        for (final lane in board.lanes)
          for (final card
              in column == BoardColumn.done
                  ? drawnDone(lane, folds)
                  : lane.cards(column))
            (lane, card),
      ];
      final doneToday = [
        for (final lane in board.lanes) ...lane.doneToday,
      ].length;
      if (column == BoardColumn.done) {
        items.add(
          _FoldLine(
            key: const ValueKey('overview-list-done'),
            label: '$doneToday done today',
            open: folds.doneOpen,
            onTap: ref.read(overviewFoldsProvider.notifier).toggleDone,
          ),
        );
      } else {
        items.add(
          Padding(
            padding: const EdgeInsets.only(top: Insets.md, bottom: Insets.xs),
            child: Text(
              '${column.label} · ${cards.length}',
              style: theme.textTheme.labelLarge?.copyWith(
                color: switch (column) {
                  BoardColumn.needsYou => semantic.attention,
                  BoardColumn.working => theme.colorScheme.primary,
                  _ => theme.colorScheme.onSurfaceVariant,
                },
              ),
            ),
          ),
        );
      }
      for (final (lane, card) in cards) {
        items.add(
          Padding(
            padding: const EdgeInsets.only(bottom: Insets.xs),
            child: OverviewCardTile(
              key: ValueKey('overview:${lane.key}:${card.id}'),
              card: card,
              density: density,
              selected: card.id == selected,
              projectLabel: lane.label,
              onTap: () => onOpen(card),
            ),
          ),
        );
      }
      if (column == BoardColumn.working && hiddenWorking > 0) {
        items.add(_HiddenWorking(count: hiddenWorking));
      }
      if (column == BoardColumn.done &&
          folds.doneOpen &&
          !folds.allDone &&
          board.lanes.any((lane) => lane.doneOlder.isNotEmpty)) {
        items.add(
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: ref.read(overviewFoldsProvider.notifier).showAllDone,
              child: const Text('Show all'),
            ),
          ),
        );
      }
    }
    return ListView.builder(
      key: const ValueKey('overview-list'),
      padding: const EdgeInsets.fromLTRB(Insets.lg, 0, Insets.lg, Insets.xl),
      itemCount: items.length,
      itemBuilder: (context, index) => items[index],
    );
  }
}
