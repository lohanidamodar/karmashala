import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_usage_providers.dart';
import 'package:agent_cli/usage.dart';
import 'package:agent_cli/discovery.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/application/environments_controller.dart';
import 'package:karmashala_session/resume.dart';
import 'agent_label.dart';
import 'settings_section.dart';

/// Usage / limits per agent installation, fetched on demand from the vendor
/// OAuth endpoints with the token each install already stores.
class UsageSection extends StatelessWidget {
  const UsageSection({required this.installations, super.key});

  final List<AgentInstallation> installations;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SettingsSection(
      title: 'USAGE & LIMITS',
      child: installations.isEmpty
          ? Text(
              'No Claude, Codex, or Antigravity installation identified.',
              style: theme.textTheme.bodySmall,
            )
          : Column(
              children: [
                for (final installation in installations)
                  _UsageCard(installation: installation),
              ],
            ),
    );
  }
}

class _UsageCard extends ConsumerStatefulWidget {
  const _UsageCard({required this.installation});

  final AgentInstallation installation;

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
    final service = ref.read(agentUsageServiceProvider);
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
    final service = ref.read(agentUsageServiceProvider);
    try {
      final environments = ref.read(executionEnvironmentDaoProvider).getAll();
      final usage = await service.fetch(widget.installation, environments);
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
      if (mounted) setState(() => _failure = UsageException('Unexpected error: $e'));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = agentLabel(widget.installation.agentId);
    final usage = _usage;
    final failure = _failure;
    return Card(
      margin: const EdgeInsets.only(bottom: Insets.sm),
      child: Padding(
        padding: const EdgeInsets.all(Insets.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
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
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
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
                  Text(
                    usage!.email!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ],
            if (failure != null) ...[
              const SizedBox(height: Insets.xs),
              _FailureLine(failure: failure),
            ],
            if (usage != null) ...[
              const SizedBox(height: Insets.xs),
              // The age, always, not only on failure: a reading that is not
              // live must not look live.
              Text(
                'Checked ${describeAge(ref.read(clockProvider).nowUtc().difference(usage.fetchedAt))}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: SemanticColors.of(context).neutral,
                ),
              ),
              // The sign-in's own lifetime, never dressed as a quota reset.
              if (usage.tokenExpiresAt case final expiry?)
                Text(
                  _signInLine(
                    expiry,
                    ref.read(clockProvider).nowUtc(),
                  ),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: SemanticColors.of(context).neutral,
                  ),
                ),
              const SizedBox(height: Insets.sm),
              if (usage.isEmpty)
                Text(
                  'No usage windows reported.',
                  style: theme.textTheme.bodySmall,
                )
              else
                for (final window in usage.windows) _UsageBar(window: window),
            ],
          ],
        ),
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
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final (icon, colour) = switch (failure.kind) {
      // A pause, not a fault: nothing is broken and nothing needs fixing.
      UsageFailureKind.rateLimited => (
        AppIcons.pauseCircle,
        semantic.attention,
      ),
      // Not red either: the vendor is unwell and the app is waiting it out.
      UsageFailureKind.serverBusy => (
        AppIcons.warningCircle,
        semantic.attention,
      ),
      UsageFailureKind.auth => (AppIcons.userCircle, semantic.failure),
      UsageFailureKind.unreachable => (AppIcons.linkBreak, semantic.neutral),
      UsageFailureKind.unusable => (AppIcons.warningCircle, semantic.failure),
      UsageFailureKind.notAsked => (AppIcons.question, semantic.neutral),
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: Chrome.iconSmall, color: colour),
        const SizedBox(width: Insets.xs),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                usageFailureHeadline(failure.kind),
                style: theme.textTheme.bodySmall?.copyWith(color: colour),
              ),
              // The service's own sentence: it is the half that says what to do.
              Text(failure.message, style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      ],
    );
  }
}

class _UsageBar extends StatelessWidget {
  const _UsageBar({required this.window});

  final UsageWindow window;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final percent = window.percent;
    // A window measured for nothing. No bar: an empty one reads as no quota.
    if (percent == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Insets.xs),
        child: Row(
          children: [
            Expanded(
              child: Text(window.label, style: theme.textTheme.bodySmall),
            ),
            Text(
              kUsageNoQuotaReported,
              style: theme.textTheme.bodySmall?.copyWith(
                color: semantic.neutral,
              ),
            ),
          ],
        ),
      );
    }
    final fraction = (percent / 100).clamp(0.0, 1.0);
    final color = percent >= 95
        ? semantic.failure
        : percent >= 80
        ? semantic.attention
        : theme.colorScheme.primary;
    final reset = window.resetsAt == null
        ? ''
        : ' · resets ${_relativeReset(window.resetsAt!)}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(window.label, style: theme.textTheme.bodySmall),
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
              value: fraction,
              minHeight: 6,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// A short relative reset time, e.g. "in 3h" / "in 2d" / "soon".
String _relativeReset(DateTime when) {
  final diff = when.difference(DateTime.now());
  if (diff.isNegative) return 'soon';
  if (diff.inDays >= 1) return 'in ${diff.inDays}d';
  if (diff.inHours >= 1) return 'in ${diff.inHours}h';
  return 'in ${diff.inMinutes}m';
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
