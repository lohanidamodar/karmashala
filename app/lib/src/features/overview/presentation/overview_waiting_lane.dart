import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../sessions/application/capacity_providers.dart';
import '../../sessions/presentation/slot_wait_notice.dart';

/// The launches waiting for a concurrency slot, in line order, each with its
/// reason; nothing while none waits.
class OverviewWaitingLane extends ConsumerWidget {
  const OverviewWaitingLane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final waiters = ref.watch(capacityNowProvider.select((c) => c.waiters));
    if (waiters.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final muted = UiDensity.of(context).muted(theme);
    return Padding(
      key: const ValueKey('overview-waiting-lane'),
      padding: const EdgeInsets.only(top: Insets.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Waiting for a slot',
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: Insets.xs),
          for (final waiter in waiters)
            Padding(
              key: ValueKey('overview-waiting:${waiter.ticketId}'),
              padding: const EdgeInsets.only(bottom: Insets.xs),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: Insets.sm,
                  vertical: Insets.xs,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(Radii.md),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  runSpacing: Insets.xxs,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          waiter.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(slotWaitText(waiter), style: muted),
                      ],
                    ),
                    SlotWaitActions(waiter: waiter),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
