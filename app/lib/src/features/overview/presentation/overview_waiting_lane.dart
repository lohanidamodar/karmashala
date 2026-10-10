import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../sessions/application/capacity_providers.dart';
import '../application/overview_prefs.dart';
import '../application/overview_today.dart';
import '../../sessions/presentation/slot_wait_notice.dart';

/// **The Waiting for a slot lane**: the launches waiting for a concurrency
/// slot, in line order, each with its reason, its place, Start anyway and
/// Cancel. Nothing while none waits, or while the Board is narrowed to what
/// a wait is not — it is stuck, and not yet running.
class OverviewWaitingLane extends ConsumerWidget {
  const OverviewWaitingLane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final waiters = ref.watch(capacityNowProvider.select((c) => c.waiters));
    final filter = ref.watch(overviewPrefsProvider.select((p) => p.filter));
    final inView =
        filter.allStates ||
        OverviewTodayPart.stuck.selectedIn(filter) ||
        OverviewTodayPart.running.selectedIn(filter);
    if (waiters.isEmpty || !inView) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final muted = UiDensity.of(context).muted(theme);
    return Padding(
      key: const ValueKey('overview-waiting-lane'),
      padding: const EdgeInsets.only(top: Insets.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          EyebrowLabel(
            'Waiting for a slot · ${waiters.length}',
            padding: const EdgeInsets.only(bottom: Insets.sm),
          ),
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
