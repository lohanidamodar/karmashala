import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_usage_providers.dart';
import 'package:agent_cli/usage.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/descriptors.dart';
import '../../environments/application/environments_controller.dart';
import '../../sessions/domain/session_resume.dart';
import '../../agents/presentation/usage_chip.dart';

/// What the selected accounts have left, shown where the fan-out is confirmed.
///
/// A fan-out starts several sessions at once, and the app already knows how much
/// of each account's quota is gone — it just never said so at the moment that
/// spends it. This puts the number beside the button.
///
/// Three rules shape it:
///
/// - **It warns, it never forbids.** Nothing here can disable the launch, and
///   the strip is deliberately a sibling of the button row rather than
///   something the button reads. The user decides.
/// - **It never blocks the dialog.** Each account's lookup is its own
///   [agentUsageProvider], watched as an [AsyncValue]; while one is in flight
///   the row says so and every other control stays live.
/// - **"Not recorded" is an answer.** An account whose usage cannot be read says
///   that, in those words. It is never shown as 0%, never as 100%, and the row
///   is never quietly dropped.
///
/// The words, the thresholds and the reset wording mirror Settings → Agents on
/// purpose: a percentage should mean one thing everywhere in the app.
class FanOutUsageStrip extends ConsumerWidget {
  const FanOutUsageStrip({required this.installations, super.key});

  /// The installations this fan-out would start a session on — one each.
  final List<AgentInstallation> installations;

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
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height < 700 ? 112 : 172,
            ),
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

    // **The value first, and never `when`.** A failed lookup carries the value
    // it had — and, across the `autoDispose` that closing this dialog causes,
    // the service's remembered reading does. Reading the error first threw both
    // away and printed "not recorded" over a number the app was holding.
    final value =
        usage.value ??
        ref.watch(agentUsageServiceProvider).remembered(installation);
    if (value == null) {
      // Slow, offline, or a token being refreshed — none of which is the
      // dialog's problem. Deliberately plain text and not a spinner: this row
      // must never be the thing that keeps the surface animating.
      return error == null
          ? _line(context, account, 'checking…')
          : _notRecorded(
              context,
              account,
              error is UsageException ? error.message : '$error',
            );
    }
    final reading = _tightest(value);
    // A reply that measured nothing is reported the same way an unreachable
    // account is: no windows at all, or windows the endpoint named and reported
    // no quota against — every Antigravity tier. Neither is 0%.
    if (reading == null) {
      return _notRecorded(
        context,
        account,
        value.isEmpty
            ? 'No usage windows reported.'
            : 'No quota reported for this account.',
      );
    }
    return _measured(
      context,
      account,
      reading,
      // A number that could not be confirmed says so, and says how old it is —
      // never silently, which would make a stale figure look live.
      note: error == null
          ? null
          : 'Last checked '
                '${describeAge(ref.read(clockProvider).nowUtc().difference(value.fetchedAt))}'
                '${error is UsageException ? ' · ${usageFailureHeadline(error.kind)}' : ''}',
    );
  }

  Widget _measured(
    BuildContext context,
    String account,
    ({UsageWindow window, double percent}) reading, {
    String? note,
  }) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final window = reading.window;
    final percent = reading.percent;
    final color = percent >= 95
        ? semantic.failure
        : percent >= 80
        ? semantic.attention
        : theme.colorScheme.primary;
    final reset = window.resetsAt == null
        ? ''
        : ' · resets ${_relativeReset(window.resetsAt!)}'
              ' (${formatResetClock(window.resetsAt!, DateTime.now())})';
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
          ClipRRect(
            borderRadius: BorderRadius.circular(Radii.sm),
            child: LinearProgressIndicator(
              value: (percent / 100).clamp(0.0, 1.0),
              minHeight: 6,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              color: color,
            ),
          ),
          if (note != null)
            Text(
              note,
              style: theme.textTheme.bodySmall?.copyWith(
                color: SemanticColors.of(context).neutral,
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
                    _warning(account, reading),
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
  String _warning(
    String account,
    ({UsageWindow window, double percent}) reading,
  ) {
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

  Widget _notRecorded(BuildContext context, String account, String reason) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _line(context, account, 'not recorded'),
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

  /// An account row with a word where the percentage would be.
  Widget _line(BuildContext context, String account, String value) {
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

/// The window closest to running out — the one a fan-out hits first — and the
/// reading it carries.
///
/// **Only windows that carry one.** [UsageWindow.percent] is null where the
/// endpoint named a window and measured nothing for it, and such a window can
/// never be the tightest: there is nothing to compare and nothing to draw. Null
/// here means this account reported no number at all, which the row says in
/// words.
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
String _relativeReset(DateTime when) {
  final diff = when.difference(DateTime.now());
  if (diff.isNegative) return 'soon';
  if (diff.inDays >= 1) return 'in ${diff.inDays}d';
  if (diff.inHours >= 1) return 'in ${diff.inHours}h';
  return 'in ${diff.inMinutes}m';
}
