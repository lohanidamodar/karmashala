import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agents/application/agent_installations_controller.dart';
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
