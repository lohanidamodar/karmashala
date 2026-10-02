import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/usage.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../agents/application/agent_providers.dart';
import '../../agents/application/agent_usage_providers.dart';
import '../../agents/presentation/agent_logo.dart';
import '../../agents/presentation/agent_version_label.dart';
import '../../agents/presentation/usage_window_meter.dart';
import '../../environments/application/environments_controller.dart';

/// **The agent cards** of the new-session dialog (UI overhaul spec §5): one
/// card per agent installed where the session will run, each saying how much
/// of its account is spent, so the choice is made with the quota in view.
class NewSessionAgentCards extends StatelessWidget {
  const NewSessionAgentCards({
    required this.installations,
    required this.selected,
    required this.onSelected,
    this.enabled = true,
    super.key,
  });

  final List<AgentInstallation> installations;
  final AgentInstallation? selected;
  final ValueChanged<AgentInstallation> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Agent',
    container: true,
    // Two across, sharing the row evenly. Rows of Expanded rather than a
    // LayoutBuilder: a dialog measures its content's intrinsic size, which a
    // LayoutBuilder refuses — the dialog failed layout and never showed.
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < installations.length; i += 2) ...[
          if (i > 0) const SizedBox(height: Insets.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _card(installations[i])),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: i + 1 < installations.length
                    ? _card(installations[i + 1])
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ],
      ],
    ),
  );

  Widget _card(AgentInstallation installation) => _AgentCard(
    key: ValueKey('agent-card:${installation.id}'),
    installation: installation,
    selected: installation.id == selected?.id,
    onTap: enabled ? () => onSelected(installation) : null,
  );
}

class _AgentCard extends ConsumerWidget {
  const _AgentCard({
    required this.installation,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final AgentInstallation installation;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tones = SurfaceTones.of(context);
    // The composed registry, so an agent added in Settings shows its name.
    final name = ref
        .watch(agentRegistryProvider)
        .displayNameFor(installation.agentId);
    final where = ref.watch(
      environmentLabelForIdProvider(installation.environmentId),
    );
    // An agent run through npx and not yet asked says so, never npx's own
    // version.
    final version = describeInstallVersion(installation);
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return Semantics(
      button: true,
      selected: selected,
      label: '$name on $where',
      excludeSemantics: true,
      child: Material(
        color: selected ? tones.selected : tones.raised,
        borderRadius: BorderRadius.circular(Radii.md),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(Radii.md),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.md,
              vertical: Insets.sm,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Radii.md),
              border: Border.all(
                color: selected ? scheme.primary : Colors.transparent,
                width: 1.5,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    AgentLogo(
                      agentId: installation.agentId,
                      size: Chrome.iconAction,
                    ),
                    const SizedBox(width: Insets.xs),
                    Expanded(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                Text(
                  version == null ? where : '$where · $version',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: muted,
                ),
                const SizedBox(height: Insets.xs),
                _AgentUsageLine(installation: installation, muted: muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The account's tightest window as a short bar and a percentage — or what
/// is known instead, in words. Never a spinner: this must not animate the
/// dialog while a lookup is slow.
class _AgentUsageLine extends ConsumerWidget {
  const _AgentUsageLine({required this.installation, required this.muted});

  final AgentInstallation installation;
  final TextStyle? muted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usage = ref.watch(agentUsageProvider(installation));
    final value = usage.value;
    if (value == null) {
      return Text(
        usage.hasError ? 'Usage unavailable' : 'Checking usage…',
        style: muted,
      );
    }
    double? tightest;
    for (final window in value.windows) {
      final percent = window.percent;
      if (percent != null && (tightest == null || percent > tightest)) {
        tightest = percent;
      }
    }
    if (tightest == null) return Text('No quota reported', style: muted);
    final fill = (tightest / 100).clamp(0.0, 1.0);
    final colour = usageSeverityColor(context, usageSeverityFor(tightest));
    return Row(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(Radii.pill),
            child: LinearProgressIndicator(
              value: fill,
              minHeight: 4,
              color: colour,
              backgroundColor: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
        ),
        const SizedBox(width: Insets.sm),
        Text('${tightest.round()}% used', style: muted),
      ],
    );
  }
}
