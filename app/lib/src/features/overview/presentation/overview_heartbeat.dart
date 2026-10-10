import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/charts.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../application/overview_activity_strips.dart';
import 'overview_counters.dart';

/// **The fleet's heartbeat**, one slim row: Today, whose parts filter the
/// cards, the facts worth a word, and the last two hours as a sparkline —
/// folded behind a toggle where the row is narrow.
class OverviewHeartbeat extends ConsumerStatefulWidget {
  const OverviewHeartbeat({super.key});

  @override
  ConsumerState<OverviewHeartbeat> createState() => _OverviewHeartbeatState();
}

class _OverviewHeartbeatState extends ConsumerState<OverviewHeartbeat> {
  var _chartOpen = false;

  /// The width under which the sparkline folds away.
  static const _sideBySide = WidthClass.mediumMin;

  /// The sparkline's least width beside the counters.
  static const _chartMin = WidthClass.mediumMin / 3;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final model = ref.watch(overviewActivityProvider);
    final chart = model.recorded
        ? _Spark(
            model: model,
            working: semantic.working,
            waiting: semantic.attention,
          )
        : null;
    const counters = Wrap(
      spacing: Insets.md,
      runSpacing: Insets.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [OverviewTodayStrip(), OverviewFactsLine()],
    );
    return Container(
      key: const ValueKey('overview-heartbeat'),
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.sm,
        vertical: Insets.xs,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.md),
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
          if (!wide) return _compactLine(chart);
          if (chart == null) return counters;
          return Row(
            children: [
              // Today's parts take the room; the chart keeps its least width.
              const Flexible(flex: 3, child: counters),
              const SizedBox(width: Insets.md),
              Expanded(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: _chartMin),
                  child: chart,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// One line where the row is narrow: the counters with something in them
  /// and the facts, sliding sideways rather than wrapping, and the chart
  /// behind a toggle.
  Widget _compactLine(Widget? chart) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      Row(
        children: [
          const Expanded(
            child: SingleChildScrollView(
              key: ValueKey('overview-triage-line'),
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OverviewTodayStrip(compact: true),
                  SizedBox(width: Insets.md),
                  OverviewFactsLine(),
                ],
              ),
            ),
          ),
          if (chart != null)
            IconButton(
              key: const ValueKey('overview-chart-toggle'),
              tooltip: _chartOpen
                  ? 'Hide the 2-hour chart'
                  : 'Show the 2-hour chart',
              visualDensity: UiDensity.of(context).controlDensity,
              iconSize: UiDensity.of(context).icon,
              onPressed: () => setState(() => _chartOpen = !_chartOpen),
              icon: Icon(_chartOpen ? AppIcons.caretUp : AppIcons.caretDown),
            ),
        ],
      ),
      if (_chartOpen && chart != null)
        Padding(
          padding: const EdgeInsets.only(bottom: Insets.xs),
          child: chart,
        ),
    ],
  );
}

/// "2h ▁▂▃▅▆ now": agents working and waiting on you over the window.
class _Spark extends StatelessWidget {
  const _Spark({
    required this.model,
    required this.working,
    required this.waiting,
  });

  final OverviewActivityModel model;
  final Color working;
  final Color waiting;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    final most = [
      for (var i = 0; i < model.working.length; i++)
        model.working[i] + model.waiting[i],
    ].fold(0, (a, b) => a > b ? a : b);
    final nowWorking = model.working.isEmpty ? 0 : model.working.last;
    final nowWaiting = model.waiting.isEmpty ? 0 : model.waiting.last;
    return Row(
      children: [
        Text('2h', style: muted),
        const SizedBox(width: Insets.sm),
        Expanded(
          child: Sparkline(
            key: const ValueKey('overview-heartbeat-chart'),
            values: [
              for (var i = 0; i < model.working.length; i++)
                (model.working[i] + model.waiting[i]).toDouble(),
            ],
            secondaryValues: [for (final n in model.waiting) n.toDouble()],
            color: working,
            secondaryColor: waiting,
            maxValue: most < 2 ? 2 : most.toDouble(),
            height: Insets.xl,
            semanticsLabel:
                'Agents over the last 2 hours: up to $most at once; now '
                '$nowWorking working and $nowWaiting waiting on you',
          ),
        ),
        const SizedBox(width: Insets.sm),
        Text('now', style: muted),
      ],
    );
  }
}
