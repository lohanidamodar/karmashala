import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/usage.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../agents/application/agent_providers.dart';
import '../../agents/application/agent_usage_providers.dart';
import '../../agents/application/folded_installations.dart';
import '../../agents/presentation/agent_logo.dart';
import '../../agents/presentation/acp_usage_note.dart';
import '../../agents/presentation/agent_version_label.dart';
import '../../agents/presentation/usage_window_meter.dart';
import '../../environments/application/environments_controller.dart';
import '../../settings/application/settings_controller.dart';

/// **The agent cards** of the new-session dialog (UI overhaul spec §5): one
/// card per agent installed where the session will run, its terminal and chat
/// forms folded into it, each saying how much of its account is spent, so the
/// choice is made with the quota in view.
///
/// A card whose agent is installed here in both forms offers Terminal | Chat;
/// the choice picks the installation underneath and is remembered for the
/// agent (`Settings.agentRunForms`).
class NewSessionAgentCards extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = foldInstallations(
      ref.watch(agentRegistryProvider),
      installations,
    );
    return Semantics(
      label: 'Agent',
      container: true,
      // Two across, sharing the row evenly. Rows of Expanded rather than a
      // LayoutBuilder: a dialog measures its content's intrinsic size, which a
      // LayoutBuilder refuses — the dialog failed layout and never showed.
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < groups.length; i += 2) ...[
            if (i > 0) const SizedBox(height: Insets.sm),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _card(ref, groups[i])),
                const SizedBox(width: Insets.sm),
                Expanded(
                  child: i + 1 < groups.length
                      ? _card(ref, groups[i + 1])
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _card(WidgetRef ref, FoldedInstallations group) {
    final picked = group.contains(selected) ? selected : null;
    final preferred = ref.watch(
      settingsControllerProvider.select(
        (s) => s.runFormFor(group.forms.agentId),
      ),
    );
    return _AgentCard(
      key: ValueKey('agent-card:${group.key}'),
      group: group,
      shown: picked ?? group.preferring(preferred),
      selected: picked != null,
      onTap: enabled ? () => onSelected(pickAgentCard(ref, group)) : null,
      onForm: enabled
          ? (form) => onSelected(pickAgentCard(ref, group, form: form))
          : null,
    );
  }
}

/// What picking [group]'s card gives: its installation in the form last chosen
/// for the agent, or in [form], which is then remembered. The tap and the
/// dialog's keys both pick through here.
AgentInstallation pickAgentCard(
  WidgetRef ref,
  FoldedInstallations group, {
  AgentRunForm? form,
}) {
  final agentId = group.forms.agentId;
  if (form == null) {
    return group.preferring(
      ref.read(settingsControllerProvider).runFormFor(agentId),
    );
  }
  ref.read(settingsControllerProvider.notifier).setAgentRunForm(agentId, form);
  return group.preferring(form);
}

class _AgentCard extends ConsumerWidget {
  const _AgentCard({
    required this.group,
    required this.shown,
    required this.selected,
    required this.onTap,
    required this.onForm,
    super.key,
  });

  final FoldedInstallations group;

  /// The installation the card stands for: the one picked, else the one a
  /// tap would pick.
  final AgentInstallation shown;
  final bool selected;
  final VoidCallback? onTap;
  final ValueChanged<AgentRunForm>? onForm;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tones = SurfaceTones.of(context);
    final name = group.forms.displayName;
    final where = ref.watch(environmentLabelForIdProvider(group.environmentId));
    // An agent run through npx and not yet asked says so, never npx's own
    // version.
    final version = describeInstallVersion(shown);
    final form = ref.watch(agentRegistryProvider).formOf(shown.agentId);
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return Material(
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
              Semantics(
                button: true,
                selected: selected,
                label: group.offersChoice
                    ? '$name on $where, ${form.label.toLowerCase()}'
                    : '$name on $where',
                excludeSemantics: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        AgentLogo(
                          agentId: group.forms.agentId,
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
                        // Not by colour alone: the chosen card says so.
                        if (selected)
                          Icon(
                            AppIcons.checkCircle,
                            size: Chrome.iconSmall,
                            color: scheme.primary,
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
                    _AgentUsageLine(group: group, muted: muted),
                  ],
                ),
              ),
              if (group.offersChoice) ...[
                const SizedBox(height: Insets.xs),
                _FormChoice(
                  keyPrefix: 'agent-form:${group.key}',
                  form: form,
                  onChanged: onForm,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Terminal | Chat, for an agent installed here in both forms.
class _FormChoice extends StatelessWidget {
  const _FormChoice({
    required this.keyPrefix,
    required this.form,
    required this.onChanged,
  });

  final String keyPrefix;
  final AgentRunForm form;
  final ValueChanged<AgentRunForm>? onChanged;

  @override
  Widget build(BuildContext context) {
    final onChanged = this.onChanged;
    final scheme = Theme.of(context).colorScheme;
    // Toggle buttons rather than a segmented button: every tap is reported,
    // so tapping the form a card already shows still picks that card. Scaled
    // down on a card too narrow for both words, as two across a phone are.
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: AlignmentDirectional.centerStart,
      child: ToggleButtons(
        isSelected: [for (final f in AgentRunForm.values) f == form],
        onPressed: onChanged == null
            ? null
            : (index) => onChanged(AgentRunForm.values[index]),
        borderRadius: BorderRadius.circular(Radii.sm),
        constraints: const BoxConstraints(minHeight: 28, minWidth: 44),
        fillColor: scheme.primary,
        selectedColor: scheme.onPrimary,
        selectedBorderColor: scheme.primary,
        textStyle: Theme.of(context).textTheme.labelMedium,
        children: [
          // Words alone: a card is half the dialog, and an icon beside
          // "Terminal" wrapped it onto two lines (seen in a probe).
          for (final f in AgentRunForm.values)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
              child: Text(
                f.label,
                key: ValueKey('$keyPrefix:${f.name}'),
                maxLines: 1,
                softWrap: false,
              ),
            ),
        ],
      ),
    );
  }
}

/// The account's tightest window as a short bar and a percentage — or what
/// is known instead, in words. Never a spinner: this must not animate the
/// dialog while a lookup is slow. Read once per card, off the terminal form:
/// both forms spend the same account.
class _AgentUsageLine extends ConsumerWidget {
  const _AgentUsageLine({required this.group, required this.muted});

  final FoldedInstallations group;
  final TextStyle? muted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // An agent only spoken to over ACP has no account to read: the protocol
    // carries no limits, only what a running session reports of itself.
    final installation = group.installationFor(AgentRunForm.terminal);
    if (installation == null) {
      return Text(kAcpUsageLimitsNote, style: muted);
    }
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
