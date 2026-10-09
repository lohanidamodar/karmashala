import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';

import '../application/capacity_providers.dart';

/// "Waiting for a slot: …", its place in line and what a person can do,
/// above session [sessionId]'s chat while it waits; nothing otherwise.
class SlotWaitNotice extends ConsumerWidget {
  const SlotWaitNotice({required this.sessionId, super.key});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wait = ref.watch(sessionSlotWaitProvider(sessionId));
    if (wait == null) return const SizedBox.shrink();
    return PaneNoticeBar(
      key: ValueKey('slot-wait:$sessionId'),
      icon: AppIcons.clock,
      tone: NoticeTone.attention,
      maxLines: 3,
      message: slotWaitText(wait),
      action: SlotWaitActions(waiter: wait),
    );
  }
}

/// The wait in one sentence, with its place in line.
String slotWaitText(LaunchWaiter wait) =>
    '${wait.reason}. ${ordinal(wait.place)} in line; it starts by itself.';

String ordinal(int n) {
  final teen = n % 100 >= 11 && n % 100 <= 13;
  final suffix = teen
      ? 'th'
      : switch (n % 10) {
          1 => 'st',
          2 => 'nd',
          3 => 'rd',
          _ => 'th',
        };
  return '$n$suffix';
}

/// Start anyway — only on a person's own start, after a confirm — and Cancel.
class SlotWaitActions extends ConsumerWidget {
  const SlotWaitActions({required this.waiter, super.key});

  final LaunchWaiter waiter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = ref.read(capacityActionsProvider);
    return Wrap(
      spacing: Insets.xs,
      children: [
        if (waiter.personStarted)
          TextButton(
            key: ValueKey('slot-wait-start-anyway:${waiter.ticketId}'),
            onPressed: () async {
              final go = await showConfirmDialog(
                context,
                title: 'Start over the limit?',
                message:
                    '"${waiter.label}" starts now, past the limit, and counts '
                    'toward it while it runs.',
                confirmLabel: 'Start anyway',
              );
              if (go) await actions.startAnyway(waiter.ticketId);
            },
            child: const Text('Start anyway'),
          ),
        TextButton(
          key: ValueKey('slot-wait-cancel:${waiter.ticketId}'),
          onPressed: () => actions.cancel(waiter.ticketId),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
