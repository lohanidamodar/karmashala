import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/tokens.dart';
import '../../agents/application/agent_installations_controller.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/application/agent_self_update_providers.dart';
import 'package:agent_cli/descriptors.dart';
import '../../environments/application/environments_controller.dart';
import '../application/settings_controller.dart';
import 'agent_label.dart';
import 'agent_usage_section.dart';
import 'claude_accounts_section.dart';
import 'codex_accounts_section.dart';
import 'settings_catalog.dart';
import 'settings_row.dart';
import 'settings_section.dart';

/// Settings → Agents → Default agent: the installation a new session
/// pre-selects.
class DefaultAgentSection extends ConsumerWidget {
  const DefaultAgentSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final settings = ref.watch(settingsControllerProvider);
    final controller = ref.read(settingsControllerProvider.notifier);
    final installations = ref.watch(agentInstallationsControllerProvider);
    // Every discovered installation, not just the kind, and the saved value is
    // clamped so the dropdown never holds an id with no matching item.
    final currentId =
        installations.any((i) => i.id == settings.defaultAgentInstallationId)
        ? settings.defaultAgentInstallationId
        : null;
    return SettingsSection(
      title: SettingsAnchor.defaultAgent.heading,
      child: installations.isEmpty
          ? Text(
              'No agents found. Press "Detect agents" below to search '
              'your environments again.',
              style: theme.textTheme.bodySmall,
            )
          : SettingsRow(
              label: 'Pre-selected when starting a session',
              control: DropdownButtonFormField<String?>(
                initialValue: currentId,
                isExpanded: true,
                items: [
                  const DropdownMenuItem(value: null, child: Text('None')),
                  for (final install in installations)
                    DropdownMenuItem(
                      value: install.id,
                      child: Text(
                        '${agentLabel(install.agentId)} · '
                        '${ref.watch(environmentLabelForIdProvider(install.environmentId))}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (id) {
                  final install = id == null
                      ? null
                      : installations.firstWhere((i) => i.id == id);
                  controller.setDefaultAgentInstallation(
                    install?.agentId,
                    install?.id,
                  );
                },
              ),
            ),
    );
  }
}

/// Settings → Agents → Agent updates: whether a launched agent may update
/// itself, and the command to update each one by hand instead.
class AgentUpdatesSection extends ConsumerWidget {
  const AgentUpdatesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final mayUpdate = ref.watch(agentsMayUpdateThemselvesProvider);
    final controller = ref.read(settingsControllerProvider.notifier);
    final registry = ref.watch(agentRegistryProvider);
    // One row per installed agent that both has a documented update command and
    // can be told not to self-update — the agents this setting governs.
    final updatable = <(String agentId, List<String> command)>[
      for (final id
          in ref
              .watch(agentInstallationsControllerProvider)
              .map((i) => i.agentId)
              .toSet())
        if (registry.byId(id)?.launch.selfUpdate case final u?)
          if (u.canSuppress && u.hasUpdateCommand) (id, u.updateCommand),
    ];
    return SettingsSection(
      title: SettingsAnchor.agentUpdates.heading,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsSwitchRow(
            label: 'Let agents update themselves in Karmashala sessions',
            help:
                'When an agent CLI starts inside Karmashala, let it check for '
                'and install its own updates. Off on Windows by default: a '
                'self-updating CLI launched under an unsigned app is a pattern '
                'behavioural antivirus (such as Bitdefender ATC) can read as a '
                'threat and kill. Turning this off does not touch updates you '
                'run yourself outside Karmashala. Applies to the next launch.',
            value: mayUpdate,
            onChanged: controller.setLetAgentsUpdateThemselves,
          ),
          if (!mayUpdate && updatable.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              'Update an agent yourself by running its own command in a '
              'terminal:',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 6),
            for (final (agentId, command) in updatable)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: '${agentLabel(agentId)}:  '),
                      TextSpan(
                        text: command.join(' '),
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: kMonoFamily,
                          fontFamilyFallback: kMonoFallback,
                        ),
                      ),
                    ],
                  ),
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// Settings → Accounts & usage → Claude accounts, for the installations found.
class InstalledClaudeAccountsSection extends ConsumerWidget {
  const InstalledClaudeAccountsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => ClaudeAccountsSection(
    installations: ref
        .watch(agentInstallationsControllerProvider)
        .where((i) => i.agentId == AgentIds.claudeCode)
        .toList(),
  );
}

/// Settings → Accounts & usage → Codex accounts, for the installations found.
class InstalledCodexAccountsSection extends ConsumerWidget {
  const InstalledCodexAccountsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => CodexAccountsSection(
    installations: ref
        .watch(agentInstallationsControllerProvider)
        .where((i) => i.agentId == AgentIds.codex)
        .toList(),
  );
}

/// Settings → Accounts & usage → Usage & limits, for the agents it can read.
class InstalledUsageSection extends ConsumerWidget {
  const InstalledUsageSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => UsageSection(
    // An allowlist, not a blocklist: an agent we have no usage endpoint for is
    // simply not offered one.
    installations: ref
        .watch(agentInstallationsControllerProvider)
        .where(
          (i) =>
              i.agentId == AgentIds.claudeCode ||
              i.agentId == AgentIds.codex ||
              i.agentId == AgentIds.antigravity,
        )
        .toList(),
  );
}
