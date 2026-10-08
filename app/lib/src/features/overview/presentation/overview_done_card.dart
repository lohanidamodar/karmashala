import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_session/delivery.dart'
    show DeliveryAction, OfferedAction;
import 'package:karmashala_ui/tokens.dart';

import '../../sessions/application/delivery_providers.dart';
import '../../sessions/application/session_actions.dart';
import '../../sessions/presentation/archive_session_action.dart';
import '../application/overview_board.dart';
import '../application/overview_providers.dart';
import '../application/overview_reads.dart';
import '../application/overview_tiles.dart';
import 'overview_card_parts.dart';
import 'overview_cards.dart';
import 'overview_resume_actions.dart';

/// What Hand back says to the parent: the sub-session is done, and what it
/// last answered.
String handBackMessage(String title, String? answer) => [
  'Sub-session “$title” is done and handed back to you.',
  if (answer != null && answer.trim().isNotEmpty) ...[
    '',
    'Its last answer:',
    '',
    answer.trim(),
  ],
].join('\n');

/// **A session done with its turn, ready to close**: its last answer and
/// diff, then Merge through the delivery strip's own action, Hand back to
/// the parent of a sub-session, and Archive.
class OverviewDoneCard extends ConsumerStatefulWidget {
  const OverviewDoneCard({required this.card, required this.onOpen, super.key});

  final OverviewCard card;
  final ValueChanged<OverviewCard> onOpen;

  @override
  ConsumerState<OverviewDoneCard> createState() => _OverviewDoneCardState();
}

class _OverviewDoneCardState extends ConsumerState<OverviewDoneCard> {
  var _busy = false;

  Future<void> _run(String done, Future<void> Function() action) async {
    if (_busy) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await action();
      messenger.showSnackBar(SnackBar(content: Text(done)));
    } on Object catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e is StateError ? e.message : '$e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final card = widget.card;
    final id = card.id;
    final native = card.entry.native;
    final merge = native == null
        ? null
        : ref
              .watch(sessionDeliveryActionsProvider(id))
              .where((o) => o.action == DeliveryAction.merge)
              .firstOrNull;
    final base = native == null
        ? null
        : ref.watch(sessionDeliveryProvider(id)).value?.baseBranch;
    final parentId = native?.parentSessionId;
    final parent = parentId == null
        ? null
        : overviewCardOf(ref.watch(overviewBoardProvider), parentId);
    final idle = !_busy;
    return OverviewCardFrame(
      card: card,
      onOpen: widget.onOpen,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          OverviewCardHeader(card: card),
          const SizedBox(height: Insets.sm),
          OverviewLatestMessage(sessionId: id),
          const SizedBox(height: Insets.xs),
          OverviewMetaLine(card: card),
          // A ready parent's sub-sessions, as a working card draws them: one
          // an agent just started was otherwise on no card at all.
          if (card.children != null) ...[
            const SizedBox(height: Insets.xs),
            OverviewSubSessions(card: card, onOpen: widget.onOpen),
          ],
          const SizedBox(height: Insets.sm),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: Insets.xs,
            runSpacing: Insets.xs,
            children: [
              if (native != null && !native.isArchived)
                OverviewArchiveGate(
                  sessionId: id,
                  builder: (resuming) => TextButton(
                    key: ValueKey('overview-done-archive:$id'),
                    onPressed: idle && !resuming
                        ? () => archiveSessionsFromUi(context, ref, [native])
                        : null,
                    child: const Text('Archive'),
                  ),
                ),
              if (parent != null)
                Tooltip(
                  message: 'Sends its last answer to ${parent.entry.title}',
                  child: OutlinedButton(
                    key: ValueKey('overview-hand-back:$id'),
                    onPressed: !idle
                        ? null
                        : () => _run(
                            'Handed back to ${parent.entry.title}',
                            () async {
                              final answer = await ref.read(
                                overviewLastAnswerProvider(id).future,
                              );
                              await ref
                                  .read(sessionActionsProvider)
                                  .continueSession(
                                    parent.id,
                                    handBackMessage(
                                      card.entry.title,
                                      answer.text,
                                    ),
                                  );
                            },
                          ),
                    child: const Text('Hand back'),
                  ),
                ),
              if (native != null)
                Tooltip(
                  message: _mergeTip(merge, base),
                  child: FilledButton(
                    key: ValueKey('overview-merge:$id'),
                    onPressed: !idle || merge == null || !merge.isEnabled
                        ? null
                        : () => _run(
                            'Asked to merge',
                            () => ref
                                .read(sessionActionsProvider)
                                .continueSession(id, merge.prompt!),
                          ),
                    child: const Text('Merge'),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// What Merge does, or why it cannot yet: the delivery strip's own words.
  static String _mergeTip(OfferedAction? merge, String? base) {
    if (merge == null) {
      return 'Nothing to merge yet: the delivery strip offers Merge once a '
          'pull request is open';
    }
    final reason = merge.disabledReason;
    if (reason != null) return reason;
    final into = base == null ? '' : ' into $base';
    return 'Asks the agent to merge its pull request$into: '
        '“${merge.prompt}”';
  }
}
