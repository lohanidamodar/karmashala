import 'dart:math' as math;

import 'package:agent_cli/usage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/charts.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../environments/application/environments_controller.dart';
import '../../application/usage_accounts.dart';
import '../../application/usage_history.dart';
import 'usage_tab_state.dart';

/// **Each machine's own readings** of an account signed in from several:
/// one line per machine over the range, from what that machine read. Only
/// drawn when there is more than one, since one machine's line is the chart
/// above it.
class UsageMachinesOverTime extends ConsumerWidget {
  const UsageMachinesOverTime({
    required this.account,
    required this.range,
    required this.now,
    super.key,
  });

  final UsageAccount account;
  final UsageRange range;
  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (account.states.length < 2) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    // From the minute, so a ticking clock does not mint a query per build.
    final minute = DateTime.utc(
      now.year,
      now.month,
      now.day,
      now.hour,
      now.minute,
    );
    final from = minute.subtract(range.span);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const EyebrowLabel('By machine'),
        const SizedBox(height: Insets.xs),
        for (final state in account.states)
          () {
            final label = ref.watch(
              environmentLabelForIdProvider(state.environmentId),
            );
            final history =
                ref
                    .watch(
                      usageHistoryProvider((
                        account: state.accountKey,
                        from: from,
                      )),
                    )
                    .value ??
                const <UsageSample>[];
            final window = _tightestLabel(state.usage);
            final values = [
              for (final s in history)
                if (s.windowLabel == window) s.percent,
            ];
            return Padding(
              key: ValueKey('usage-machine-${state.environmentId}'),
              padding: const EdgeInsets.symmetric(vertical: Insets.xs),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      window == null ? label : '$label · $window',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  const SizedBox(width: Insets.sm),
                  if (values.length < 2)
                    Text('no readings', style: muted)
                  else
                    Flexible(
                      child: Sparkline(
                        values: values,
                        color: SemanticColors.of(context).working,
                        maxValue: math.max(100, values.reduce(math.max)),
                        width: 160,
                        semanticsLabel:
                            '$label: ${values.length} readings of $window '
                            'in ${range.phrase}, last '
                            '${values.last.round()}%',
                      ),
                    ),
                ],
              ),
            );
          }(),
      ],
    );
  }

  /// The label of the window [usage] is tightest on, or null.
  static String? _tightestLabel(AgentUsage? usage) {
    UsageWindow? tightest;
    for (final w in usage?.windows ?? const <UsageWindow>[]) {
      final p = w.percent;
      if (p != null && (tightest == null || p > tightest.percent!)) {
        tightest = w;
      }
    }
    return tightest?.label;
  }
}
