import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show CapacityScope;
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../../app/shell/workbench_tabs.dart' show openSettingsTab;
import '../../../../app/widgets/fact_list.dart';
import '../../../../core/capabilities/capabilities.dart';
import '../../../../core/util/clock_provider.dart';
import '../../../environments/application/environments_controller.dart';
import '../../../sessions/application/capacity_providers.dart';
import '../../../settings/application/settings_controller.dart';
import '../../../settings/presentation/settings_catalog.dart'
    show SettingsAnchor;
import '../../application/usage_accounts.dart';
import '../../application/usage_forecast.dart';
import '../../application/usage_limits.dart';
import '../usage_chip.dart' show formatResetClock;
import '../usage_window_meter.dart' show usageForecastSentence;

/// **Limits beside usage** (round 84): how full each scope the account runs
/// in is, who waits, the pause on new background work and the usage hold —
/// round 79's limits, read here and changed in Settings → Session limits.
/// Above them, when the forecast runs out before the reset while work holds
/// the account's slots, a one-tap pause until the reset.
class UsageLimitsSection extends ConsumerWidget {
  const UsageLimitsSection({
    required this.account,
    required this.forecasts,
    super.key,
  });

  final UsageAccount account;
  final Map<String, UsageForecast> forecasts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final offered = ref.watch(
      capabilitiesProvider.select((c) => c.sessionCapacity),
    );
    // Wraps rather than squeezes: at a phone's width and a large text size
    // the link goes under the label.
    final header = Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        const EyebrowLabel('Limits'),
        TextButton.icon(
          key: const ValueKey('usage-limits-settings'),
          onPressed: () =>
              openSettingsTab(ref, anchor: SettingsAnchor.sessionLimits),
          icon: const Icon(AppIcons.gearSix, size: Chrome.iconAction),
          label: const Text('Session limits'),
        ),
      ],
    );
    if (!offered) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          Text(
            'This server does not hold session limits, so there is nothing '
            'to show beside the usage.',
            style: muted,
          ),
        ],
      );
    }
    final capacity = ref.watch(capacityNowProvider);
    final limits = ref.watch(
      settingsControllerProvider.select((s) => s.launchLimits),
    );
    final now = ref.watch(clockProvider).nowUtc();
    final until = ref.watch(usagePauseUntilProvider);
    final waiters = usageWaitersOf(capacity);
    final suggestion = usagePauseSuggestion(
      account: account,
      forecasts: forecasts,
      capacity: capacity,
    );
    String labelOf(UsageLimitLine line) => switch (line.scope) {
      CapacityScope.global => 'All sessions',
      CapacityScope.machine => ref.watch(
        environmentLabelForIdProvider(line.key),
      ),
      CapacityScope.account =>
        'This account on '
            '${ref.watch(environmentLabelForIdProvider(line.key.split('@').last))}',
      CapacityScope.project => line.key,
    };
    final hold = limits.holdBackgroundAbovePercent;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        if (suggestion != null)
          _PauseSuggestion(forecast: suggestion, now: now),
        for (final line in usageLimitLinesOf(account, capacity))
          FactRow(
            key: ValueKey('usage-limit-${line.scope.name}-${line.key}'),
            icon: switch (line.scope) {
              CapacityScope.machine => AppIcons.terminalWindow,
              CapacityScope.account => AppIcons.userCircle,
              _ => AppIcons.stack,
            },
            label: labelOf(line),
            value: _Value(line.occupancy, attention: line.isFull),
          ),
        FactRow(
          key: const ValueKey('usage-limit-waiting'),
          icon: AppIcons.clock,
          label: 'Waiting for a slot',
          value: _Value(
            waiters.all == 0
                ? 'none'
                : '${waiters.all}'
                      '${waiters.background == 0 ? '' : ' · ${waiters.background} background'}',
            attention: waiters.all > 0,
          ),
        ),
        FactRow(
          key: const ValueKey('usage-limit-hold'),
          icon: AppIcons.slidersHorizontal,
          label: 'Usage hold',
          value: _Value(
            hold == null
                ? 'off'
                : 'background waits above $hold% of the 5-hour window',
          ),
        ),
        MergeSemantics(
          child: FactRow(
            key: const ValueKey('usage-limit-pause'),
            icon: AppIcons.pauseCircle,
            label: until != null && limits.pauseBackground
                ? 'Background paused until ${formatResetClock(until, now)}'
                : 'Pause new background work',
            value: Switch(
              value: limits.pauseBackground,
              onChanged: (paused) {
                ref.read(usagePauseUntilProvider.notifier).forget();
                ref
                    .read(settingsControllerProvider.notifier)
                    .setBackgroundPaused(paused);
              },
            ),
          ),
        ),
      ],
    );
  }
}

/// A row's value: small, tabular, in the warning colour when it needs a look.
class _Value extends StatelessWidget {
  const _Value(this.text, {this.attention = false});

  final String text;
  final bool attention;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      textAlign: TextAlign.end,
      style: theme.textTheme.bodySmall?.copyWith(
        fontFeatures: const [FontFeature.tabularFigures()],
        color: attention
            ? SemanticColors.of(context).attention
            : theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// "Pause background work until 15:04?" — one tap, round 79's own pause.
class _PauseSuggestion extends ConsumerWidget {
  const _PauseSuggestion({required this.forecast, required this.now});

  final UsageForecast forecast;
  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final attention = SemanticColors.of(context).attention;
    final reset = forecast.resetsAt!;
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.sm),
      child: DecoratedBox(
        key: const ValueKey('usage-pause-suggestion'),
        decoration: BoxDecoration(
          border: Border.all(color: attention),
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        child: Padding(
          padding: const EdgeInsets.all(Insets.md),
          child: Wrap(
            spacing: Insets.md,
            runSpacing: Insets.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Pause background work until '
                    '${formatResetClock(reset, now)}?',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    '${forecast.windowLabel}: '
                    '${usageForecastSentence(forecast, now)}. Running '
                    'sessions carry on; new background starts wait.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: attention,
                    ),
                  ),
                ],
              ),
              FilledButton.tonal(
                key: const ValueKey('usage-pause-until-reset'),
                onPressed: () => ref
                    .read(usagePauseUntilProvider.notifier)
                    .pauseUntil(reset),
                child: const Text('Pause'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
