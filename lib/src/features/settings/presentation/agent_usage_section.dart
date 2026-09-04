import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_usage_providers.dart';
import '../../agents/data/agent_usage_service.dart';
import '../../agents/domain/agent_installation.dart';
import '../../agents/domain/agent_usage.dart';
import '../../agents/domain/usage_failure.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/application/environments_controller.dart';
import '../../sessions/domain/session_resume.dart';
import 'agent_label.dart';
import 'settings_section.dart';

/// Usage / limits per agent installation (Claude + Codex): fetched on demand
/// from the vendor OAuth endpoints using the token each install already stores.
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
              'No Claude or Codex installation identified.',
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
    // The chip and this card are one account, so the card opens on whatever was
    // last read — with its age. A blank card was hiding a number the app
    // already had, and "Check usage" was spending a request to learn it again.
    final service = ref.read(agentUsageServiceProvider);
    _usage = service.remembered(widget.installation);
    // And why it is not moving, if it is not: a card that looked untroubled
    // while the chip showed a stalled reading is how the two surfaces came to
    // disagree about one account.
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
      // The reading survives the failure that follows it — losing a number you
      // had is worse than showing an old one that says how old it is.
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
            if (failure != null) ...[
              const SizedBox(height: Insets.xs),
              _FailureLine(failure: failure),
            ],
            if (usage != null) ...[
              const SizedBox(height: Insets.xs),
              // The age, always, and never only when something failed: a
              // reading that is not live must not look live, which is the rule
              // `AgentStatusReport.evidenceAt` and the system health panel are
              // both written to.
              Text(
                'Checked ${describeAge(ref.read(clockProvider).nowUtc().difference(usage.fetchedAt))}',
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

/// **Why there is no fresh number**, in the words each failure deserves.
///
/// Four situations used to arrive as one red sentence, and the user can act
/// differently on every one: a rate limit needs them to stop asking, an expired
/// token needs them to run the agent once, an unreachable endpoint needs
/// nothing at all. The icon and the colour follow the same rule the system
/// health panel is built to — neutral for "nobody's fault", and never a red
/// mark on something that is merely waiting.
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
      // Not red either: the vendor is unwell, the user did nothing wrong, and
      // the app is already waiting it out.
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
              // The service's own sentence, verbatim: it is the half that says
              // what to do — run the agent once, wait two minutes, or nothing.
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
    final fraction = (window.percent / 100).clamp(0.0, 1.0);
    final semantic = SemanticColors.of(context);
    final color = window.percent >= 95
        ? semantic.failure
        : window.percent >= 80
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
                '${window.percent.toStringAsFixed(0)}%$reset',
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
