import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_usage_providers.dart';
import 'package:agent_cli/usage.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/descriptors.dart';
import '../../environments/application/environments_controller.dart';
import 'package:karmashala_session/resume.dart';
import '../../agents/presentation/usage_chip.dart';
import '../../agents/presentation/usage_window_meter.dart';
import 'package:karmashala_ui/charts.dart';

/// What the selected accounts have left, beside the button that spends it. It
/// warns and never forbids, never blocks the dialog, and says "not recorded".
class FanOutUsageStrip extends ConsumerWidget {
  const FanOutUsageStrip({
    required this.installations,
    this.maxHeight = defaultMaxHeight,
    super.key,
  });

  static const defaultMaxHeight = 172.0;

  /// On a short form the strip is the block that yields.
  static const compactMaxHeight = 112.0;

  /// The installations this fan-out would start a session on — one each.
  final List<AgentInstallation> installations;

  /// The most the account rows take before they scroll. The strip sits in a
  /// Column and cannot measure the height it has, so its form decides.
  final double maxHeight;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (installations.isEmpty) return const SizedBox.shrink();

    // Grouped by account, not by installation: usage belongs to the
    // (agent, environment) pair, so two installs of one CLI in one environment
    // are one quota — asked once, printed once, and spending two sessions.
    final accounts = <String, List<AgentInstallation>>{};
    for (final install in installations) {
      accounts
          .putIfAbsent('${install.agentId}@${install.environmentId}', () => [])
          .add(install);
    }

    final total = installations.length;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: Insets.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Starts $total ${total == 1 ? 'session' : 'sessions'}',
            style: theme.textTheme.labelLarge,
          ),
          // Bounded and scrollable: a fan-out across many accounts must not
          // push the launch button out of a 720x560 window, and on a window
          // that short the strip is the block that yields.
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final group in accounts.values)
                    _AccountUsage(
                      installation: group.first,
                      sessions: group.length,
                      totalSessions: total,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One account's tightest window: the limit this fan-out runs into first.
class _AccountUsage extends ConsumerWidget {
  const _AccountUsage({
    required this.installation,
    required this.sessions,
    required this.totalSessions,
  });

  final AgentInstallation installation;

  /// How many of this fan-out's sessions run on this account.
  final int sessions;

  /// How many the fan-out starts in total.
  final int totalSessions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account =
        '${AgentRegistry.builtIn.displayNameFor(installation.agentId)} · '
        '${ref.watch(environmentLabelForIdProvider(installation.environmentId))}';
    final usage = ref.watch(agentUsageProvider(installation));
    final error = usage.error;
    final now = ref.watch(clockProvider).nowUtc();

    // **The value first, and never `when`.** A failed lookup carries the value it
    // had; reading the error first printed "not recorded" over a held number.
    final value =
        usage.value ??
        ref.watch(agentUsageServiceProvider).remembered(installation);
    if (value == null) {
      // Slow, offline, or a token being refreshed — none of which is the
      // dialog's problem. Deliberately plain text and not a spinner: this row
      // must never be the thing that keeps the surface animating.
      return error == null
          ? _UsageLine(account: account, value: 'checking…')
          : _UsageUnavailable(
              account: account,
              reason: error is UsageException ? error.message : '$error',
            );
    }
    final reading = _tightest(value);
    // A reply that measured nothing is reported the same way an unreachable
    // account is: no windows at all, or windows the endpoint named and reported
    // no quota against — every Antigravity tier. Neither is 0%.
    if (reading == null) {
      return _UsageUnavailable(
        account: account,
        reason: value.isEmpty
            ? 'No usage windows reported.'
            : 'No quota reported for this account.',
      );
    }
    return _UsageMeter(
      account: account,
      reading: reading,
      now: now,
      readAt: value.fetchedAt,
      sessions: sessions,
      totalSessions: totalSessions,
      // A number that could not be confirmed says so, and says how old it is —
      // never silently, which would make a stale figure look live.
      note: error == null
          ? null
          : 'Last checked '
                '${describeAge(now.difference(value.fetchedAt))}'
                '${error is UsageException ? ' · ${usageFailureHeadline(error.kind)}' : ''}',
    );
  }
}

/// A measured window: the account, the percentage and reset, a bar, and a
/// warning once it is nearly spent.
class _UsageMeter extends StatelessWidget {
  const _UsageMeter({
    required this.account,
    required this.reading,
    required this.now,
    required this.readAt,
    required this.sessions,
    required this.totalSessions,
    this.note,
  });

  final String account;
  final ({UsageWindow window, double percent}) reading;

  /// From `clockProvider`, so the reset reads against the app's clock.
  final DateTime now;

  /// When the percentage was measured, for the pace tick.
  final DateTime readAt;
  final int sessions;
  final int totalSessions;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final window = reading.window;
    final percent = reading.percent;
    final color = usageSeverityColor(context, usageSeverityFor(percent));
    final reset = window.resetsAt == null
        ? ''
        : ' · resets ${relativeReset(window.resetsAt!, now)}'
              ' (${formatResetClock(window.resetsAt!, now)})';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '$account · ${window.label}',
                  style: theme.textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '${percent.toStringAsFixed(0)}%$reset',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
          const SizedBox(height: 2),
          LinearMeter(
            value: percent / 100,
            marker: usagePace(window, readAt).elapsed,
            color: color,
            semanticsLabel:
                '$account · ${window.label}: '
                '${percent.toStringAsFixed(0)}% used$reset',
          ),
          if (note case final note?)
            Text(
              note,
              style: theme.textTheme.bodySmall?.copyWith(
                color: semantic.neutral,
              ),
            ),
          if (percent >= 80) ...[
            const SizedBox(height: Insets.xs),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(AppIcons.warning, size: Chrome.iconSmall, color: color),
                const SizedBox(width: Insets.xs),
                Expanded(
                  child: Text(
                    _warning(),
                    style: theme.textTheme.bodySmall?.copyWith(color: color),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// What is left, beside what this fan-out spends on it. Both halves are
  /// measured — how much a session *consumes* is not, so nothing here projects
  /// a total.
  String _warning() {
    final label = reading.window.label;
    final head = reading.percent >= 100
        ? 'No $label limit left on $account'
        : 'Only ${(100 - reading.percent).toStringAsFixed(0)}% left on '
              '$account ($label)';
    return '$head — ${_cost()}';
  }

  String _cost() {
    if (sessions == totalSessions) {
      return totalSessions == 1
          ? 'this session runs on it.'
          : 'all $totalSessions sessions run on it.';
    }
    return '$sessions of the $totalSessions sessions '
        '${sessions == 1 ? 'runs' : 'run'} on it.';
  }
}

/// An account whose usage could not be read, and why.
class _UsageUnavailable extends StatelessWidget {
  const _UsageUnavailable({required this.account, required this.reason});

  final String account;
  final String reason;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _UsageLine(account: account, value: 'not recorded'),
        Padding(
          padding: const EdgeInsets.only(bottom: Insets.xs),
          child: Text(
            reason,
            style: theme.textTheme.bodySmall?.copyWith(
              color: SemanticColors.of(context).neutral,
            ),
          ),
        ),
      ],
    );
  }
}

/// An account row with a word where the percentage would be.
class _UsageLine extends StatelessWidget {
  const _UsageLine({required this.account, required this.value});

  final String account;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: Insets.xs),
      child: Row(
        children: [
          Expanded(
            child: Text(
              account,
              style: theme.textTheme.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            value,
            style: theme.textTheme.bodySmall?.copyWith(
              color: SemanticColors.of(context).neutral,
            ),
          ),
        ],
      ),
    );
  }
}

/// The window closest to running out, and its reading. Only windows that carry
/// one: a null percent can never be the tightest, and null here means none did.
({UsageWindow window, double percent})? _tightest(AgentUsage usage) {
  ({UsageWindow window, double percent})? tightest;
  for (final window in usage.windows) {
    final percent = window.percent;
    if (percent == null) continue;
    if (tightest == null || percent > tightest.percent) {
      tightest = (window: window, percent: percent);
    }
  }
  return tightest;
}

/// A short relative reset time, in the settings page's words.
String relativeReset(DateTime when, DateTime now) {
  final diff = when.difference(now);
  if (diff.isNegative) return 'soon';
  if (diff.inDays >= 1) return 'in ${diff.inDays}d';
  if (diff.inHours >= 1) return 'in ${diff.inHours}h';
  return 'in ${diff.inMinutes}m';
}
