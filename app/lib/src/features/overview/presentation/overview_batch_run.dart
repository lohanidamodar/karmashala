import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show DataRefused;
import 'package:karmashala_session/delivery.dart' show DeliveryAction;
import 'package:karmashala_ui/dialogs.dart';

import '../../../core/capabilities/capabilities.dart';
import '../../explorer/application/agent_states.dart';
import '../../sessions/application/delivery_providers.dart';
import '../../sessions/application/session_actions.dart';
import '../../sessions/application/session_detach.dart';
import '../../sessions/application/session_turn_interrupt.dart';
import '../../sessions/presentation/archive_session_action.dart';
import '../../sessions/presentation/end_session_action.dart';
import '../application/overview_batch.dart';
import '../application/overview_batch_actions.dart';
import '../application/overview_board.dart';
import '../application/overview_prefs.dart';

/// [card] as a batch verb reads it — by the rules the session menu offers
/// each verb by.
OverviewBatchFacts overviewBatchFactsOf(WidgetRef ref, OverviewCard card) {
  final native = card.entry.native;
  final pinned = ref.read(overviewPrefsProvider).pinned.contains(card.id);
  if (native == null) {
    return OverviewBatchFacts(native: false, pinned: pinned);
  }
  final merge = ref
      .read(sessionDeliveryActionsProvider(card.id))
      .where((o) => o.action == DeliveryAction.merge)
      .firstOrNull;
  return OverviewBatchFacts(
    archived: native.isArchived,
    live: sessionIsLive(ref, native),
    runs: sessionRunsNow(ref, card.id),
    working: card.state == AgentState.working || card.state == AgentState.quiet,
    canDetach:
        ref.read(capabilitiesProvider).detachSessions &&
        native.parentSessionId != null,
    mergeable: merge != null && merge.isEnabled && merge.prompt != null,
    pinned: pinned,
  );
}

/// Does [plan] — asking once first, with the list, when its verb is
/// destructive — and says how it went in one snack bar, each failure named.
Future<void> runOverviewBatch(
  BuildContext context,
  WidgetRef ref,
  OverviewBatchPlan plan,
  List<OverviewCard> cards,
) async {
  if (plan.isEmpty) return;
  final titleOf = {for (final card in cards) card.id: card.entry.title};
  final verb = plan.verb;
  if (verb.destructive) {
    final names = [for (final id in plan.apply) '• ${titleOf[id]}'].join('\n');
    final left = plan.skipped.isEmpty
        ? ''
        : '\n\nLeft as they are: '
              '${[for (final MapEntry(:key, :value) in plan.skipped.entries) '"${titleOf[key]}" is $value'].join('; ')}.';
    final go = await showConfirmDialog(
      context,
      title:
          '${verb.label} ${plan.apply.length} '
          'session${plan.apply.length == 1 ? '' : 's'}?',
      message: '$names$left${_consequence(verb)}',
      confirmLabel: '${verb.label} ${plan.apply.length}',
    );
    if (!go || !context.mounted) return;
  }
  final messenger = ScaffoldMessenger.maybeOf(context);
  final failed = <String, String>{};
  var done = 0;
  if (verb == OverviewBatchVerb.archive) {
    // One request for every one, as the session menu's Archive sends.
    try {
      final result = await ref
          .read(sessionActionsProvider)
          .archiveSessions(plan.apply);
      done = result.changed.length;
      for (final live in result.live) {
        failed[live.title] = 'still running';
      }
    } on Object catch (error) {
      for (final id in plan.apply) {
        failed[titleOf[id]!] = _words(error);
      }
    }
  } else {
    for (final id in plan.apply) {
      final why = await _runOne(ref, verb, id);
      if (why == null) {
        done++;
      } else {
        failed[titleOf[id]!] = why;
      }
    }
  }
  ref.read(overviewSelectionProvider.notifier).clear();
  messenger?.showSnackBar(
    SnackBar(
      key: const ValueKey('overview-batch-result'),
      content: Text(
        overviewBatchResult(
          verb,
          done: done,
          skipped: {
            for (final MapEntry(:key, :value) in plan.skipped.entries)
              titleOf[key]!: value,
          },
          failed: failed,
        ),
      ),
    ),
  );
}

String _consequence(OverviewBatchVerb verb) => switch (verb) {
  OverviewBatchVerb.stop => '\n\nEach running turn is stopped, as Esc would.',
  OverviewBatchVerb.end =>
    '\n\nEach process is stopped now; the conversations stay, to resume.',
  OverviewBatchVerb.archive =>
    '\n\nThey are hidden with their ended sub-sessions. Worktrees are kept.',
  OverviewBatchVerb.detach =>
    '\n\nEach becomes a session of its own; its parent stops hearing from it.',
  OverviewBatchVerb.merge =>
    '\n\nEach agent is asked to merge its pull request.',
  OverviewBatchVerb.pin || OverviewBatchVerb.unpin => '',
};

/// Does [verb] to [id] through the session menu's own path; why it failed,
/// or null.
Future<String?> _runOne(
  WidgetRef ref,
  OverviewBatchVerb verb,
  String id,
) async {
  try {
    switch (verb) {
      case OverviewBatchVerb.stop:
        return await ref.read(sessionTurnInterruptProvider)(id);
      case OverviewBatchVerb.end:
        return await endSessionProcess(ref, id) ? null : 'nothing ran it';
      case OverviewBatchVerb.detach:
        await ref.read(sessionDetachProvider)(id);
        return null;
      case OverviewBatchVerb.merge:
        final merge = ref
            .read(sessionDeliveryActionsProvider(id))
            .where((o) => o.action == DeliveryAction.merge)
            .firstOrNull;
        final prompt = merge?.prompt;
        if (merge == null || !merge.isEnabled || prompt == null) {
          return 'nothing to merge';
        }
        await ref.read(sessionActionsProvider).continueSession(id, prompt);
        return null;
      case OverviewBatchVerb.pin:
      case OverviewBatchVerb.unpin:
        return ref.read(overviewPrefsProvider.notifier).togglePin(id)
            ? null
            : 'the board already holds $kOverviewPinLimit pins';
      case OverviewBatchVerb.archive:
        // Archived together by the caller.
        return null;
    }
  } on Object catch (error) {
    return _words(error);
  }
}

String _words(Object error) => switch (error) {
  DataRefused(:final message) => message,
  StateError(:final message) => message,
  _ => '$error',
};
