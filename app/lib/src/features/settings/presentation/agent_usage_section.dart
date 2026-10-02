import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/charts.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_usage_providers.dart';
import 'package:agent_cli/usage.dart';
import '../../agents/presentation/usage_history_charts.dart';
import '../../agents/presentation/usage_window_meter.dart';
import 'package:agent_cli/discovery.dart';
import '../../environments/application/environments_controller.dart';
import 'package:karmashala_session/resume.dart';
import 'agent_label.dart';
import 'settings_catalog.dart';
import 'settings_section.dart';
import 'settings_notice.dart';
import 'usage_tokens_card.dart';

/// Usage / limits per agent installation, fetched on demand from the vendor
/// OAuth endpoints with the token each install already stores.
class UsageSection extends ConsumerStatefulWidget {
  const UsageSection({required this.installations, super.key});

  final List<AgentInstallation> installations;

  @override
  ConsumerState<UsageSection> createState() => _UsageSectionState();
}

class _UsageSectionState extends ConsumerState<UsageSection> {
  @override
  Widget build(BuildContext context) {
    final installations = widget.installations;
    return SettingsSection(
      title: SettingsAnchor.usage.heading,
      child: installations.isEmpty
          ? const SettingsNotice(
              message:
                  'No Claude, Codex, or Antigravity installation identified.',
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _AccountComparison(installations: installations),
                for (final installation in installations)
                  _UsageCard(
                    installation: installation,
                    // A card's reading changes what the comparison shows.
                    onReading: () => setState(() {}),
                  ),
                const UsageTokensCard(),
              ],
            ),
    );
  }
}

/// The tightest measured window of every account the app has a reading for,
/// side by side — only once there are two to compare.
class _AccountComparison extends ConsumerWidget {
  const _AccountComparison({required this.installations});

  final List<AgentInstallation> installations;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bars = <BarDatum>[];
    final seen = <String>{};
    for (final installation in installations) {
      if (!seen.add(usageAccountKey(installation))) continue;
      final usage = ref
          .watch(accountUsageProvider(usageAccountKey(installation)))
          ?.usage;
      if (usage == null) continue;
      UsageWindow? tightest;
      for (final window in usage.windows) {
        final percent = window.percent;
        if (percent == null) continue;
        if (tightest == null || percent > tightest.percent!) tightest = window;
      }
      if (tightest == null) continue;
      final percent = tightest.percent!;
      bars.add(
        BarDatum(
          label:
              '${agentLabel(ref, installation.agentId)} · '
              '${ref.watch(environmentLabelForIdProvider(installation.environmentId))}'
              ' · ${tightest.label}',
          value: percent.clamp(0, 100).toDouble(),
          valueLabel: '${percent.round()}% used',
          color: usageSeverityColor(context, usageSeverityFor(percent)),
        ),
      );
    }
    if (bars.length < 2) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return SettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Closest to a limit, per account',
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: Insets.xs),
          RankedBars(
            bars: bars,
            maxValue: 100,
            color: SemanticColors.of(context).idle,
          ),
        ],
      ),
    );
  }
}

class _UsageCard extends ConsumerStatefulWidget {
  const _UsageCard({required this.installation, required this.onReading});

  final AgentInstallation installation;
  final VoidCallback onReading;

  @override
  ConsumerState<_UsageCard> createState() => _UsageCardState();
}

class _UsageCardState extends ConsumerState<_UsageCard> {
  bool _loading = false;
  AgentUsage? _usage;
  UsageException? _failure;

  @override
  void initState() {
    super.initState();
    // The card opens on whatever was last read, with its age: a blank one was
    // hiding a number the app already had.
    final service = ref.read(usageReadingsProvider);
    _usage = service.remembered(widget.installation);
    // And why it is not moving: a card that looked untroubled beside a stalled
    // chip is how the two surfaces came to disagree about one account.
    _failure = service.pendingPause(widget.installation);
  }

  Future<void> _fetch() async {
    setState(() {
      _loading = true;
      _failure = null;
    });
    final service = ref.read(usageReadingsProvider);
    try {
      final usage = await service.fetch(widget.installation);
      if (mounted) setState(() => _usage = usage);
    } on UsageException catch (e) {
      // The reading survives the failure after it: an aged number beats none.
      if (mounted) {
        setState(() {
          _failure = e;
          _usage = service.remembered(widget.installation) ?? _usage;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _failure = UsageException('Unexpected error: $e'));
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        widget.onReading();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = agentLabel(ref, widget.installation.agentId);
    final usage = _usage;
    final failure = _failure;
    final now = ref.watch(clockProvider).nowUtc();
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: SemanticColors.of(context).neutral,
    );
    return SettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '$label · '
                  '${ref.watch(environmentLabelForIdProvider(widget.installation.environmentId))}',
                  style: MonoStyles.body,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_loading)
                const InlineSpinner(semanticsLabel: 'Checking usage')
              else
                TextButton.icon(
                  onPressed: _fetch,
                  icon: const Icon(
                    AppIcons.arrowsClockwise,
                    size: Chrome.iconAction,
                  ),
                  label: Text(usage == null ? 'Check usage' : 'Refresh'),
                ),
            ],
          ),
          if (usage?.email != null) ...[
            const SizedBox(height: Insets.xs),
            Row(
              children: [
                Icon(
                  AppIcons.userCircle,
                  size: 13,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: Insets.xs),
                Flexible(
                  child: Text(
                    usage!.email!,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (failure != null) ...[
            const SizedBox(height: Insets.xs),
            _FailureLine(failure: failure),
          ],
          if (usage == null && failure == null) ...[
            const SizedBox(height: Insets.xs),
            Text(
              _loading
                  ? 'Reading this account’s limits…'
                  : 'Not read yet. Limits are read with the sign-in this agent '
                        'already has, when you ask or while a session on it is '
                        'open.',
              style: muted,
            ),
          ],
          if (usage != null) ...[
            const SizedBox(height: Insets.xs),
            // The age, always, not only on failure: a reading that is not
            // live must not look live.
            Text(
              'Checked ${describeAge(now.difference(usage.fetchedAt))}',
              style: muted,
            ),
            // The sign-in's own lifetime, never dressed as a quota reset.
            if (usage.tokenExpiresAt case final expiry?)
              Text(_signInLine(expiry, now), style: muted),
            const SizedBox(height: Insets.sm),
            if (usage.isEmpty)
              Text(
                'No usage windows reported.',
                style: theme.textTheme.bodySmall,
              )
            else ...[
              for (final window in usage.windows)
                UsageWindowMeter(
                  window: window,
                  readAt: usage.fetchedAt,
                  now: now,
                ),
              const SizedBox(height: Insets.sm),
              UsageHistoryPanel(
                accountKey: usageAccountKey(widget.installation),
                usage: usage,
                now: now,
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// **Why there is no fresh number**, in each failure's own words — and never a
/// red mark on something that is merely waiting.
class _FailureLine extends StatelessWidget {
  const _FailureLine({required this.failure});

  final UsageException failure;

  @override
  Widget build(BuildContext context) {
    final (icon, tone) = switch (failure.kind) {
      // A pause, not a fault: nothing is broken and nothing needs fixing.
      UsageFailureKind.rateLimited => (
        AppIcons.pauseCircle,
        SettingsNoticeTone.attention,
      ),
      // Not red either: the vendor is unwell and the app is waiting it out.
      UsageFailureKind.serverBusy => (
        AppIcons.warningCircle,
        SettingsNoticeTone.attention,
      ),
      UsageFailureKind.auth => (AppIcons.userCircle, SettingsNoticeTone.danger),
      UsageFailureKind.unreachable => (
        AppIcons.linkBreak,
        SettingsNoticeTone.neutral,
      ),
      UsageFailureKind.unusable => (
        AppIcons.warningCircle,
        SettingsNoticeTone.danger,
      ),
      UsageFailureKind.notAsked => (
        AppIcons.question,
        SettingsNoticeTone.neutral,
      ),
    };
    return SettingsNotice(
      tone: tone,
      icon: icon,
      message: usageFailureHeadline(failure.kind),
      // The service's own sentence: it is the half that says what to do.
      detail: failure.message,
    );
  }
}

/// **When the sign-in behind a reading lapses**, in this card's words. Read
/// against the app's clock, not [DateTime.now], so a test can pin it.
String _signInLine(DateTime expiry, DateTime now) {
  final left = expiry.difference(now);
  if (left <= Duration.zero) {
    return 'Sign-in expired — run the agent once to refresh it';
  }
  if (left.inDays >= 1) return 'Sign-in expires in ${left.inDays}d';
  if (left.inHours >= 1) return 'Sign-in expires in ${left.inHours}h';
  return 'Sign-in expires in ${left.inMinutes}m';
}
