import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../agents/application/agent_usage_providers.dart';
import '../../agents/data/agent_usage_service.dart';
import '../../agents/domain/agent_installation.dart';
import '../../agents/domain/agent_usage.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/application/environments_controller.dart';
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
  String? _error;

  Future<void> _fetch() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final environments = ref.read(executionEnvironmentDaoProvider).getAll();
      final usage = await ref
          .read(agentUsageServiceProvider)
          .fetch(widget.installation, environments);
      if (mounted) setState(() => _usage = usage);
    } on UsageException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Unexpected error: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = agentLabel(widget.installation.agentId);
    final usage = _usage;
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
            if (_error != null) ...[
              const SizedBox(height: Insets.xs),
              Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            if (usage != null) ...[
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
