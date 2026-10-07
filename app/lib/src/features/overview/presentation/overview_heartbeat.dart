import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/charts.dart';
import 'package:karmashala_ui/tokens.dart';

import '../application/overview_activity_strips.dart';
import '../application/overview_providers.dart';
import '../timeline/domain/timeline_model.dart';
import 'overview_counters.dart';

/// **The fleet's heartbeat**: how many agents worked and waited on you over
/// the last two hours, the live counters that filter the cards, and the facts
/// worth a line.
class OverviewHeartbeat extends ConsumerWidget {
  const OverviewHeartbeat({super.key});

  /// The width under which the chart goes below the counters.
  static const _sideBySide = WidthClass.mediumMin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final model = ref.watch(overviewActivityProvider);
    final (:strip, :doneToday) = ref.watch(overviewCountersProvider);
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final worked = model.workedTotal;
    final summary = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const OverviewCounters(),
        const SizedBox(height: Insets.sm),
        Text(
          model.recorded
              ? worked == Duration.zero
                    ? 'No agent worked in the last 2 hours.'
                    : '${describeDuration(worked)} of agent time in the last '
                          '2 hours · $doneToday done today'
              : 'The activity log could not be read, so the last 2 hours '
                    'are not drawn.',
          key: const ValueKey('overview-heartbeat-said'),
          style: muted,
        ),
        const Padding(
          padding: EdgeInsets.only(top: Insets.xs),
          child: OverviewFactsLine(),
        ),
      ],
    );
    final chart = !model.recorded
        ? null
        : _Chart(model: model, working: semantic.working, waiting: semantic.attention);
    return Container(
      key: const ValueKey('overview-heartbeat'),
      padding: const EdgeInsets.all(Insets.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          final wide =
              box.maxWidth >=
              WidthClass.scaleBreakpoint(
                _sideBySide,
                MediaQuery.textScalerOf(context),
              );
          if (chart == null) return summary;
          if (!wide) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [summary, const SizedBox(height: Insets.md), chart],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Flexible(flex: 5, child: summary),
              const SizedBox(width: Insets.xl),
              Expanded(flex: 6, child: chart),
            ],
          );
        },
      ),
    );
  }
}

class _Chart extends StatelessWidget {
  const _Chart({
    required this.model,
    required this.working,
    required this.waiting,
  });

  final OverviewActivityModel model;
  final Color working;
  final Color waiting;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final most = [
      for (var i = 0; i < model.working.length; i++)
        model.working[i] + model.waiting[i],
    ].fold(0, (a, b) => a > b ? a : b);
    final nowWorking = model.working.isEmpty ? 0 : model.working.last;
    final nowWaiting = model.waiting.isEmpty ? 0 : model.waiting.last;
    Widget key(Color color, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: Insets.sm + Insets.xxs,
          height: Insets.sm + Insets.xxs,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(Insets.xxs),
          ),
        ),
        const SizedBox(width: Insets.xs),
        Text(label, style: muted),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Sparkline(
          key: const ValueKey('overview-heartbeat-chart'),
          values: [
            for (var i = 0; i < model.working.length; i++)
              (model.working[i] + model.waiting[i]).toDouble(),
          ],
          secondaryValues: [for (final n in model.waiting) n.toDouble()],
          color: working,
          secondaryColor: waiting,
          maxValue: most < 2 ? 2 : most.toDouble(),
          height: Insets.xxl + Insets.xl,
          semanticsLabel:
              'Agents over the last 2 hours: up to $most at once; now '
              '$nowWorking working and $nowWaiting waiting on you',
        ),
        const SizedBox(height: Insets.xs),
        Row(
          children: [
            Text('2h ago', style: muted),
            const Spacer(),
            Text('1h', style: muted),
            const Spacer(),
            Text('now', style: muted?.copyWith(fontWeight: FontWeight.w700)),
          ],
        ),
        const SizedBox(height: Insets.xs),
        Wrap(
          spacing: Insets.md,
          children: [
            key(working, 'working'),
            key(waiting, 'waiting on you'),
          ],
        ),
      ],
    );
  }
}
