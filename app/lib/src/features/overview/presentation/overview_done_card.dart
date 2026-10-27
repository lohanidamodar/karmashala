import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_session/delivery.dart'
    show DeliveryAction, OfferedAction;
import 'package:karmashala_session/session.dart' show Session;

import '../../explorer/application/agent_states.dart';
import '../../sessions/application/delivery_providers.dart';
import '../../sessions/application/session_actions.dart';
import '../../sessions/presentation/archive_session_action.dart';
import '../application/overview_board.dart';
import '../application/overview_providers.dart';
import '../application/overview_reads.dart';
import '../application/overview_tiles.dart';
import '../application/overview_tree.dart';

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

/// The parent on the board that [card] can hand its answer back to: only
/// once its turn is over, never mid-work.
OverviewCard? overviewHandBackParent(WidgetRef ref, OverviewCard card) {
  final parentId = card.entry.native?.parentSessionId;
  final finished =
      card.state == AgentState.ready || card.state == AgentState.ended;
  if (parentId == null || !finished) return null;
  return overviewCardOf(ref.read(overviewBoardProvider), parentId);
}

/// Sends [card]'s last answer to [parent], saying so.
Future<void> handBackFromDashboard(
  BuildContext context,
  WidgetRef ref,
  OverviewCard card,
  OverviewCard parent,
) => _run(context, 'Handed back to ${parent.entry.title}', () async {
  final answer = await ref.read(overviewLastAnswerProvider(card.id).future);
  await ref
      .read(sessionActionsProvider)
      .continueSession(
        parent.id,
        handBackMessage(card.entry.title, answer.text),
      );
});

/// The delivery strip's own Merge for [card]; null while there is nothing
/// to merge.
OfferedAction? overviewMergeOffer(WidgetRef ref, OverviewCard card) {
  if (card.entry.native == null) return null;
  return ref
      .read(sessionDeliveryActionsProvider(card.id))
      .where((o) => o.action == DeliveryAction.merge)
      .firstOrNull;
}

/// Asks [card]'s agent to merge, in the delivery strip's own words.
Future<void> mergeFromDashboard(
  BuildContext context,
  WidgetRef ref,
  OverviewCard card,
  OfferedAction merge,
) => _run(
  context,
  'Asked to merge',
  () =>
      ref.read(sessionActionsProvider).continueSession(card.id, merge.prompt!),
);

/// The rows of [node]'s family not yet archived: what its Archive takes.
List<Session> overviewFamilyToArchive(OverviewTreeNode node) => [
  for (final card in node.drawn) ?card.entry.native,
].where((s) => !s.isArchived).toList();

/// Archives [node]'s whole family, through the lists' own path.
Future<void> archiveFamilyFromDashboard(
  BuildContext context,
  WidgetRef ref,
  OverviewTreeNode node,
) async {
  final family = overviewFamilyToArchive(node);
  if (family.isEmpty) return;
  await archiveSessionsFromUi(context, ref, family);
}

Future<void> _run(
  BuildContext context,
  String done,
  Future<void> Function() action,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await action();
    messenger?.showSnackBar(SnackBar(content: Text(done)));
  } on Object catch (e) {
    messenger?.showSnackBar(
      SnackBar(content: Text(e is StateError ? e.message : '$e')),
    );
  }
}
