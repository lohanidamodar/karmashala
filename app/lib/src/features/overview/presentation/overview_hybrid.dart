import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../sessions/application/session_status_providers.dart';
import '../application/overview_board.dart';
import '../application/overview_prefs.dart';
import '../application/overview_providers.dart';
import 'overview_cards.dart';
import 'overview_filters.dart';
import 'overview_heartbeat.dart';
import 'overview_queue_card.dart';
import '../../sessions/presentation/prompt_cards/question_prompt_card.dart';

/// What the Overview draws, in reading order.
typedef OverviewSections = ({
  List<OverviewCard> queue,
  List<OverviewCard> work,
  List<OverviewCard> done,
});

/// What is at work, as groups: each lane — project, machine or context — and
/// its working and ready cards, in the board's lane order.
List<(OverviewLane, List<OverviewCard>)> overviewWorkGroupsOf(
  OverviewBoard board,
) => [
  for (final lane in board.lanes)
    if ([
      ...lane.cards(BoardColumn.working),
      ...lane.cards(BoardColumn.ready),
    ] case final cards when cards.isNotEmpty)
      (lane, byUrgency(cards)),
];

/// [board]'s cards as the Overview lays them out: what waits on you, asks
/// before failures and oldest wait first; what is at work, lane by lane and
/// most urgent first; what ended today, newest first.
OverviewSections overviewSectionsOf(
  OverviewBoard board, {
  required DateTime? Function(String id) waitingSince,
}) {
  final queue = [
    for (final lane in board.lanes) ...lane.cards(BoardColumn.needsYou),
  ];
  DateTime since(OverviewCard card) =>
      waitingSince(card.id) ?? card.entry.activityAt;
  queue.sort((a, b) {
    final rank = overviewUrgency(a.state).compareTo(overviewUrgency(b.state));
    if (rank != 0) return rank;
    final byWait = since(a).compareTo(since(b));
    return byWait != 0 ? byWait : a.id.compareTo(b.id);
  });
  final done = [for (final lane in board.lanes) ...lane.doneToday]
    ..sort((a, b) => b.entry.activityAt.compareTo(a.entry.activityAt));
  return (
    queue: queue,
    work: [for (final (_, cards) in overviewWorkGroupsOf(board)) ...cards],
    done: done,
  );
}

/// **The Overview, hybrid**: the fleet's heartbeat on top, what waits on you
/// on the left — answerable in place — and what is at work on the right, each
/// card with its last two hours. On a phone, the queue first, then the work.
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
  var _doneOpen = false;

  /// The narrowest a work card is drawn at 1x text, and the most across.
  static const _cardMin = WidthClass.mediumMin / 2;
  static const _maxAcross = 3;

  /// The queue's column beside the work, and the least room for both.
  // No layout token names a side column's width yet.
  static const _queueWidth = 380.0;
  static const _sideBySide = WidthClass.expandedMin;

  @override
  Widget build(BuildContext context) {
    final board = ref.watch(overviewBoardProvider);
    final statusOf = ref.read(sessionStatusLookupProvider);
    for (final lane in board.lanes) {
      for (final card in lane.cards(BoardColumn.needsYou)) {
        ref.watch(agentSessionStatusProvider(card.id));
      }
    }
    final sections = overviewSectionsOf(
      board,
      waitingSince: (id) => statusOf(id)?.waitingSince,
    );
    final hasFilters = ref.watch(overviewActiveFiltersProvider).isNotEmpty;
    final allStates = ref.watch(
      overviewPrefsProvider.select((p) => p.filter.allStates),
    );
    final theme = Theme.of(context);
    final muted = UiDensity.of(context).muted(theme);
    final onOpen = widget.onOpen;

    return LayoutBuilder(
      builder: (context, box) {
        final scaler = MediaQuery.textScalerOf(context);
        final gutter = box.maxWidth < WidthClass.mediumMin
            ? Insets.lg
            : Insets.xl;
        final inner = box.maxWidth - gutter * 2;
        final sideBySide =
            sections.queue.isNotEmpty &&
            inner >= WidthClass.scaleBreakpoint(_sideBySide, scaler);
        final workWidth = sideBySide ? inner - _queueWidth - Insets.xl : inner;
        final across =
            ((workWidth + Insets.md) /
                    (WidthClass.scaleBreakpoint(_cardMin, scaler) + Insets.md))
                .floor()
                .clamp(1, _maxAcross);

        final queue = Column(
          key: const ValueKey('overview-queue'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            EyebrowLabel(
              'Waiting on you · ${sections.queue.length}',
              padding: const EdgeInsets.only(bottom: Insets.sm),
            ),
            for (final card in sections.queue)
              Padding(
                padding: const EdgeInsets.only(bottom: Insets.md),
                child: OverviewQueueCard(
                  key: ValueKey('overview-queue-card:${card.id}'),
                  card: card,
                  onOpen: onOpen,
                  onEdit: widget.onEdit,
                  onTerminal: widget.onTerminal,
                  onAnswered: widget.onAnswered,
                  questionController: widget.questionControllerOf?.call(
                    card.id,
                  ),
                ),
              ),
          ],
        );
        final work = Column(
          key: const ValueKey('overview-work'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            EyebrowLabel(
              'At work · ${sections.work.length}',
              padding: const EdgeInsets.only(bottom: Insets.sm),
            ),
            if (sections.work.isEmpty)
              Text(
                allStates
                    ? 'Nothing is running or ready right now.'
                    : 'Nothing here right now.',
                key: const ValueKey('overview-none-at-work'),
                style: muted,
              )
            else
              for (final (lane, cards) in overviewWorkGroupsOf(board)) ...[
                Padding(
                  key: ValueKey('overview-work-group:${lane.key}'),
                  padding: const EdgeInsets.only(
                    top: Insets.xs,
                    bottom: Insets.sm,
                  ),
                  child: Text(
                    '${lane.label} · ${cards.length}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                ..._grid([
                  for (final card in cards)
                    OverviewWorkCard(
                      key: ValueKey('overview-work-card:${card.id}'),
                      card: card,
                      onOpen: onOpen,
                    ),
                ], across),
              ],
          ],
        );
        final done = sections.done;

        return ListView(
          key: const ValueKey('overview-hybrid'),
          padding: EdgeInsets.fromLTRB(gutter, Insets.md, gutter, Insets.xxl),
          children: [
            const OverviewHeartbeat(),
            if (hasFilters)
              const Padding(
                padding: EdgeInsets.only(top: Insets.md),
                child: OverviewActiveFilterChips(),
              ),
            const SizedBox(height: Insets.lg),
            if (sideBySide)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: _queueWidth, child: queue),
                  const SizedBox(width: Insets.xl),
                  Expanded(child: work),
                ],
              )
            else ...[
              if (sections.queue.isNotEmpty) ...[
                queue,
                const SizedBox(height: Insets.sm),
              ],
              work,
            ],
            if (done.isNotEmpty) ...[
              const SizedBox(height: Insets.lg),
              _FoldLine(
                label: '${done.length} done today',
                open: _doneOpen,
                onTap: () => setState(() => _doneOpen = !_doneOpen),
              ),
              if (_doneOpen)
                for (final card in done)
                  OverviewDoneRow(card: card, onOpen: onOpen),
            ],
          ],
        );
      },
    );
  }

  /// [cards] in rows of [across], each row as tall as its tallest.
  static List<Widget> _grid(List<Widget> cards, int across) => [
    for (var start = 0; start < cards.length; start += across)
      Padding(
        padding: const EdgeInsets.only(bottom: Insets.md),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = start; i < start + across; i++) ...[
                if (i > start) const SizedBox(width: Insets.md),
                Expanded(
                  child: i < cards.length ? cards[i] : const SizedBox.shrink(),
                ),
              ],
            ],
          ),
        ),
      ),
  ];
}

/// "4 done today ▸".
class _FoldLine extends StatelessWidget {
  const _FoldLine({
    required this.label,
    required this.open,
    required this.onTap,
  });

  final String label;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Semantics(
      button: true,
      expanded: open,
      label: label,
      excludeSemantics: true,
      child: Align(
        alignment: Alignment.centerLeft,
        child: InkWell(
          key: const ValueKey('overview-done-fold'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(Radii.sm),
          child: TouchTarget(
            child: Padding(
              padding: const EdgeInsets.all(Insets.xs),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(color: muted),
                    ),
                  ),
                  const SizedBox(width: Insets.xs),
                  Icon(
                    open ? AppIcons.caretDown : AppIcons.caretRight,
                    size: UiDensity.of(context).iconSmall,
                    color: muted,
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
