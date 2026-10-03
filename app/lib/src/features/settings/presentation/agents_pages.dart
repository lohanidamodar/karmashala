import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agents/application/agent_installations_controller.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/application/agent_self_update_providers.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import '../../environments/application/environments_controller.dart';
import '../application/settings_controller.dart';
import 'agent_label.dart';
import 'claude_accounts_section.dart';
import 'codex_accounts_section.dart';
import 'settings_catalog.dart';
import 'settings_row.dart';
import 'settings_section.dart';

/// Settings → Agents and accounts → Default agent: the installation a new
/// session pre-selects.
class DefaultAgentSection extends StatelessWidget {
  const DefaultAgentSection({super.key});

  @override
  Widget build(BuildContext context) => SettingsSection(
    title: SettingsAnchor.defaultAgent.heading,
    child: const DefaultAgentRow(),
  );
}

/// The row itself — the dropdown over every discovered installation, or the
/// note that there is none — so the Agents page's header strip can hold it.
class DefaultAgentRow extends ConsumerWidget {
  const DefaultAgentRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    final controller = ref.read(settingsControllerProvider.notifier);
    final installations = ref.watch(agentInstallationsControllerProvider);
    if (installations.isEmpty) {
      return const SettingsNote(
        'No agents found. Discover agents looks for them on every machine.',
      );
    }
    // Every discovered installation, not just the kind, and the saved value is
    // clamped so the dropdown never holds an id with no matching item.
    final currentId =
        installations.any((i) => i.id == settings.defaultAgentInstallationId)
        ? settings.defaultAgentInstallationId
        : null;
    return SettingsRow(
      label: 'Agent for new sessions',
      help: 'Pre-selected when starting a session.',
      control: DropdownButtonFormField<String?>(
        initialValue: currentId,
        isExpanded: true,
        items: [
          const DropdownMenuItem(value: null, child: Text('None')),
          for (final install in installations)
            DropdownMenuItem(
              value: install.id,
              child: Text(
                '${agentLabel(ref, install.agentId)} · '
                '${ref.watch(environmentLabelForIdProvider(install.environmentId))}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: (id) {
          final install = id == null
              ? null
              : installations.firstWhere((i) => i.id == id);
          controller.setDefaultAgentInstallation(install?.agentId, install?.id);
        },
      ),
    );
  }
}

/// Settings → Agents and accounts → Agent updates: whether a launched agent may
/// update itself, and the command to update each one by hand instead.
class AgentUpdatesSection extends ConsumerWidget {
  const AgentUpdatesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
            help: 'Off on Windows by default, where antivirus may kill it.',
            value: mayUpdate,
            onChanged: controller.setLetAgentsUpdateThemselves,
          ),
          // One row per agent: its update command is the row's value, in the
          // ledger hand, so it reads as something to type.
          if (!mayUpdate && updatable.isNotEmpty) ...[
            const SettingsNote(
              'Update an agent yourself by running its own command in a '
              'terminal:',
            ),
            for (final (agentId, command) in updatable)
              SettingsRow(
                label: agentLabel(ref, agentId),
                control: SettingsValue(
                  label: command.join(' '),
                  mono: true,
                  tooltip: command.join(' '),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// Settings → Agents and accounts → Claude accounts: the installations whose
/// agent signs in through Anthropic's OAuth login.
class InstalledClaudeAccountsSection extends ConsumerWidget {
  const InstalledClaudeAccountsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => ClaudeAccountsSection(
    installations: _installationsWhere(
      ref,
      (adapter) => adapter.accounts is AnthropicOAuthAccounts,
    ),
  );
}

/// Settings → Agents and accounts → Codex accounts: the installations whose
/// agent signs in through an OpenAI `auth.json`.
class InstalledCodexAccountsSection extends ConsumerWidget {
  const InstalledCodexAccountsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => CodexAccountsSection(
    installations: _installationsWhere(
      ref,
      (adapter) => adapter.accounts is OpenAiAuthFileAccounts,
    ),
  );
}

/// The found installations whose agent's adapter passes [test].
List<AgentInstallation> _installationsWhere(
  WidgetRef ref,
  bool Function(AgentAdapter adapter) test,
) {
  final registry = ref.watch(agentRegistryProvider);
  return [
    for (final installation in ref.watch(agentInstallationsControllerProvider))
      if (registry.adapterFor(installation.agentId) case final adapter?
          when test(adapter))
        installation,
  ];
}
