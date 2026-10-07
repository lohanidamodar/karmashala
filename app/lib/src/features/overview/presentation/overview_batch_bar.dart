import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/widgets/adaptive_modal.dart';
import '../../sessions/application/session_status_providers.dart';
import '../../sessions/presentation/approval_request_card.dart';
import '../application/overview_batch.dart';
import '../application/overview_board.dart';
import '../application/overview_providers.dart';
import '../application/overview_quick_message.dart';
import '../application/overview_tiles.dart';
import 'overview_hybrid.dart';

/// The selected sessions still on the board, in the order it draws them.
List<OverviewCard> overviewSelectedCards(WidgetRef ref) {
  final selection = ref.watch(overviewSelectionProvider);
  if (selection.isEmpty) return const [];
  final board = ref.watch(overviewBoardProvider);
  return [
    for (final id in overviewDrawnOrder(ref))
      if (selection.contains(id)) ?overviewCardOf(board, id),
  ];
}

/// The ids ↑ and ↓ walk, and a Shift-click spans: as the board draws them.
List<String> overviewDrawnOrder(WidgetRef ref) {
  final statusOf = ref.read(sessionStatusLookupProvider);
  final sections = overviewSectionsOf(
    ref.read(overviewBoardProvider),
    waitingSince: (id) => statusOf(id)?.waitingSince,
  );
  return [
    for (final card in [...sections.queue, ...sections.work, ...sections.ready])
      card.id,
  ];
}

/// A pick with Ctrl or Shift held, a long press, or under a thumb while some
/// are picked: true when it changed the selection rather than meaning "open".
bool overviewPickSelects(
  WidgetRef ref,
  OverviewCard card, {
  bool long = false,
  bool touch = false,
}) {
  final keys = HardwareKeyboard.instance;
  final selection = ref.read(overviewSelectionProvider.notifier);
  if (keys.isShiftPressed && !touch) {
    selection.extendTo(card.id, overviewDrawnOrder(ref));
    return true;
  }
  if (long ||
      keys.isControlPressed ||
      keys.isMetaPressed ||
      (touch && !ref.read(overviewSelectionProvider).isEmpty)) {
    selection.toggle(card.id);
    return true;
  }
  return false;
}

/// Whether a card's checkbox is drawn: on what waits on you once there is
/// more than one to answer, and on every card while some are picked.
bool watchOverviewSelectable(WidgetRef ref, OverviewCard card) {
  if (!ref.watch(overviewSelectionProvider.select((s) => s.isEmpty))) {
    return true;
  }
  if (card.column != BoardColumn.needsYou) return false;
  return ref.watch(
    overviewBoardProvider.select(
      (board) =>
          board.lanes.fold(
            0,
            (n, lane) => n + lane.cards(BoardColumn.needsYou).length,
          ) >
          1,
    ),
  );
}

/// The box that picks [card] for a batch reply; nothing when not offered.
class OverviewSelectBox extends ConsumerWidget {
  const OverviewSelectBox({required this.card, super.key});

  final OverviewCard card;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!watchOverviewSelectable(ref, card)) return const SizedBox.shrink();
    final picked = ref.watch(
      overviewSelectionProvider.select((s) => s.contains(card.id)),
    );
    return Padding(
      padding: const EdgeInsets.only(right: Insets.xs),
      child: Checkbox(
        key: ValueKey('overview-select:${card.id}'),
        value: picked,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: UiDensity.of(context).isTouch
            ? MaterialTapTargetSize.padded
            : MaterialTapTargetSize.shrinkWrap,
        semanticLabel: 'Select ${card.entry.title}',
        onChanged: (_) =>
            ref.read(overviewSelectionProvider.notifier).toggle(card.id),
      ),
    );
  }
}

/// **Answering several at once**: shown only while sessions are picked.
/// A message goes to every one; Allow and Deny only when every one waits on
/// the very same command in the very same folder.
class OverviewBatchBar extends ConsumerWidget {
  const OverviewBatchBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cards = overviewSelectedCards(ref);
    if (cards.isEmpty) return const SizedBox.shrink();
    for (final card in cards) {
      ref.watch(agentSessionStatusProvider(card.id));
    }
    final theme = Theme.of(context);
    final muted = UiDensity.of(context).muted(theme);
    final n = cards.length;
    final ids = [for (final card in cards) card.id];
    final approval = sharedBatchApproval(
      ids,
      statusOf: ref.read(sessionStatusLookupProvider),
      folderOf: (id) =>
          cards.firstWhere((c) => c.id == id).entry.directory?.path,
    );
    bool offersAll(BoardApproval kind) =>
        approval != null &&
        ids.every((id) => boardApprovalOffers(ref, id).contains(kind));
    final statusOf = ref.read(sessionStatusLookupProvider);
    final allApprovals = ids.every(
      (id) => statusOf(id)?.hasOpenPrompt ?? false,
    );
    return Material(
      key: const ValueKey('overview-batch-bar'),
      color: theme.colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.lg,
          vertical: Insets.sm,
        ),
        child: Wrap(
          spacing: Insets.sm,
          runSpacing: Insets.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '$n selected',
              key: const ValueKey('overview-batch-count'),
              style: theme.textTheme.labelLarge,
            ),
            FilledButton.tonalIcon(
              key: const ValueKey('overview-batch-message'),
              onPressed: () => _message(context, ref, cards),
              icon: const Icon(AppIcons.chatCircle),
              label: Text('Send a message to $n'),
            ),
            if (offersAll(BoardApproval.allow))
              FilledButton(
                key: const ValueKey('overview-batch-allow'),
                onPressed: () => _allow(context, ref, cards, approval!),
                child: Text('Allow $n'),
              ),
            if (offersAll(BoardApproval.deny))
              OutlinedButton(
                key: const ValueKey('overview-batch-deny'),
                onPressed: () =>
                    _answer(context, ref, cards, BoardApproval.deny),
                child: Text('Deny $n'),
              ),
            if (approval == null && allApprovals && n > 1)
              Text(
                'Different commands — answer each',
                key: const ValueKey('overview-batch-differ'),
                style: muted,
              ),
            TextButton(
              key: const ValueKey('overview-batch-clear'),
              onPressed: ref.read(overviewSelectionProvider.notifier).clear,
              child: const Text('Clear'),
            ),
          ],
        ),
      ),
    );
  }

  static String _names(List<OverviewCard> cards) =>
      [for (final card in cards) '• ${card.entry.title}'].join('\n');

  Future<void> _allow(
    BuildContext context,
    WidgetRef ref,
    List<OverviewCard> cards,
    BatchApproval approval,
  ) async {
    final go = await showConfirmDialog(
      context,
      title: 'Allow ${cards.length} sessions to run this?',
      message: '${approval.subject}\nin ${approval.folder}\n\n${_names(cards)}',
      confirmLabel: 'Allow ${cards.length}',
    );
    if (!go || !context.mounted) return;
    await _answer(context, ref, cards, BoardApproval.allow);
  }

  Future<void> _answer(
    BuildContext context,
    WidgetRef ref,
    List<OverviewCard> cards,
    BoardApproval kind,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final selection = ref.read(overviewSelectionProvider.notifier);
    final refused = <String>[];
    for (final card in cards) {
      final why = await answerBoardApproval(ref, card.id, kind);
      if (why != null) refused.add('"${card.entry.title}": $why');
    }
    selection.clear();
    final done = cards.length - refused.length;
    final verb = kind == BoardApproval.allow ? 'Allowed' : 'Denied';
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          [
            if (done > 0) '$verb $done.',
            if (refused.isNotEmpty) 'Not answered: ${refused.join('; ')}',
          ].join(' '),
        ),
      ),
    );
  }

  Future<void> _message(
    BuildContext context,
    WidgetRef ref,
    List<OverviewCard> cards,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final selection = ref.read(overviewSelectionProvider.notifier);
    final quick = ref.read(overviewQuickMessageProvider);
    final text = await showAdaptiveModal<String>(
      context: context,
      title: 'Message ${cards.length} sessions',
      builder: (_) => _BatchMessage(cards: cards),
    );
    if (text == null || text.trim().isEmpty) return;
    final failed = <String>[];
    var queued = 0;
    for (final card in cards) {
      try {
        if (await quick.send(card.id, text.trim()) ==
            QuickMessageOutcome.queued) {
          queued++;
        }
      } on Object catch (error) {
        failed.add(
          '"${card.entry.title}": '
          '${error is StateError ? error.message : error}',
        );
      }
    }
    selection.clear();
    final sent = cards.length - failed.length;
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          [
            if (sent > 0)
              'Sent to $sent'
                  '${queued > 0 ? ' · $queued queued behind a turn' : ''}.',
            if (failed.isNotEmpty) 'Not sent to ${failed.join('; ')}.',
          ].join(' '),
        ),
      ),
    );
  }
}

/// The message to every picked session, and who it goes to.
class _BatchMessage extends StatefulWidget {
  const _BatchMessage({required this.cards});

  final List<OverviewCard> cards;

  @override
  State<_BatchMessage> createState() => _BatchMessageState();
}

class _BatchMessageState extends State<_BatchMessage> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _send() {
    if (_text.text.trim().isEmpty) return;
    Navigator.of(context).pop(_text.text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = UiDensity.of(context).muted(theme);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            [for (final card in widget.cards) card.entry.title].join(' · '),
            key: const ValueKey('overview-batch-names'),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: muted,
          ),
          const SizedBox(height: Insets.sm),
          TextField(
            key: const ValueKey('overview-batch-text'),
            controller: _text,
            autofocus: true,
            minLines: 2,
            maxLines: 6,
            keyboardType: TextInputType.multiline,
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'What to say to each…',
            ),
          ),
          const SizedBox(height: Insets.md),
          Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              spacing: Insets.sm,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                ListenableBuilder(
                  listenable: _text,
                  builder: (context, _) => FilledButton(
                    key: const ValueKey('overview-batch-send'),
                    onPressed: _text.text.trim().isEmpty ? null : _send,
                    child: Text('Send to ${widget.cards.length}'),
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
