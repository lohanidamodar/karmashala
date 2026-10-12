import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_session/delivery.dart'
    show DeliveryAction, OfferedAction;
import 'package:karmashala_ui/tokens.dart';

import '../../explorer/application/agent_states.dart';
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
/// diff, then its close actions ([OverviewCloseActions]) — and, as a
/// family's root on the tree, its [footer] and Archive family.
class OverviewDoneCard extends StatelessWidget {
  const OverviewDoneCard({
    required this.card,
    required this.onOpen,
    this.leading = 0,
    this.footer,
    this.family = const [],
    super.key,
  });

  final OverviewCard card;
  final ValueChanged<OverviewCard> onOpen;

  /// See [OverviewCardFrame.leading]; with it, the avatar names the agent.
  final double leading;
  final Widget? footer;

  /// The sessions below it on the tree, archived with it by Archive family.
  final List<OverviewCard> family;

  @override
  Widget build(BuildContext context) => OverviewCardFrame(
    card: card,
    onOpen: onOpen,
    leading: leading,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        OverviewCardHeader(card: card, ring: leading == 0),
        const SizedBox(height: Insets.sm),
        OverviewLatestMessage(sessionId: card.id),
        const SizedBox(height: Insets.xs),
        OverviewMetaLine(card: card),
        if (footer case final footer?) ...[
          const SizedBox(height: Insets.xs),
          footer,
        ],
        const SizedBox(height: Insets.sm),
        OverviewCloseActions(card: card, family: family),
      ],
    ),
  );
}

/// **Closing a session from the board**: Archive; Hand back, to the parent
/// of a sub-session; Merge, through the delivery strip's own action, when
/// [merge]; Archive family, with a [family] below it; then [extra].
class OverviewCloseActions extends ConsumerStatefulWidget {
  const OverviewCloseActions({
    required this.card,
    this.merge = true,
    this.family = const [],
    this.extra = const [],
    super.key,
  });

  final OverviewCard card;
  final bool merge;
  final List<OverviewCard> family;
  final List<Widget> extra;

  @override
  ConsumerState<OverviewCloseActions> createState() =>
      _OverviewCloseActionsState();
}

class _OverviewCloseActionsState extends ConsumerState<OverviewCloseActions> {
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
    final merge = native == null || !widget.merge
        ? null
        : ref
              .watch(sessionDeliveryActionsProvider(id))
              .where((o) => o.action == DeliveryAction.merge)
              .firstOrNull;
    final base = merge == null
        ? null
        : ref.watch(sessionDeliveryProvider(id)).value?.baseBranch;
    final parentId = native?.parentSessionId;
    // Handed back once its turn is over, never mid-work.
    final finished =
        card.state == AgentState.ready || card.state == AgentState.ended;
    final parent = parentId == null || !finished
        ? null
        : overviewCardOf(ref.watch(overviewBoardProvider), parentId);
    final family = [
      ?native,
      for (final below in widget.family) ?below.entry.native,
    ].where((s) => !s.isArchived).toList();
    final idle = !_busy;
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: Insets.xs,
      runSpacing: Insets.xs,
      children: [
        if (widget.family.isNotEmpty && family.isNotEmpty)
          TextButton(
            key: ValueKey('overview-archive-family:$id'),
            onPressed: idle
                ? () => archiveSessionsFromUi(context, ref, family)
                : null,
            child: const Text('Archive family'),
          )
        else if (native != null && !native.isArchived)
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
                  : () =>
                        _run('Handed back to ${parent.entry.title}', () async {
                          final answer = await ref.read(
                            overviewLastAnswerProvider(id).future,
                          );
                          await ref
                              .read(sessionActionsProvider)
                              .continueSession(
                                parent.id,
                                handBackMessage(card.entry.title, answer.text),
                              );
                        }),
              child: const Text('Hand back'),
            ),
          ),
        ...widget.extra,
        if (native != null && widget.merge)
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
