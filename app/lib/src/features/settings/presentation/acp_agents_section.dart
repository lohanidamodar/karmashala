import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../agents/application/acp_agent_providers.dart';
import '../../agents/application/agent_installations_controller.dart';
import 'acp_agent_dialog.dart';
import 'acp_builtin_agent_row.dart' show acpAgentsNote;
import 'acp_user_agent_row.dart';
import 'agents_group_section.dart';
import 'settings_section.dart';

/// Settings → Agents and accounts → **Your ACP agents**: the agents a person
/// added — from the public registry or by hand — one row each with the
/// command that starts it, Edit and Remove, and the button that adds one.
class AcpAgentsSection extends ConsumerWidget {
  const AcpAgentsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(acpAgentRowsProvider);
    final setup = ref.watch(acpAgentsSetupProvider);
    final installations = ref.watch(agentInstallationsControllerProvider);
    final theme = Theme.of(context);
    return AgentsGroupSection(
      title: 'Your ACP agents',
      count: rows.length,
      trailing: setup.discovering
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const InlineSpinner(),
                const SizedBox(width: Insets.sm),
                Text('Discovering…', style: theme.textTheme.bodySmall),
              ],
            )
          : TextButton.icon(
              onPressed: () => AcpAgentDialog.show(context),
              icon: const Icon(AppIcons.plus),
              label: const Text('Add ACP agent…'),
            ),
      children: [
        if (setup.discoveryError case final error?)
          Padding(
            padding: const EdgeInsets.only(bottom: Insets.sm),
            child: DesktopErrorBanner(error),
          ),
        if (rows.isEmpty)
          const SettingsNote(
            'No ACP agents added. Any agent that speaks the Agent Client '
            'Protocol over stdio can be added from the registry or as a '
            'command.',
          )
        else ...[
          const SettingsNote(acpAgentsNote),
          for (final row in rows)
            AcpUserAgentRow(
              row: row,
              installs: [
                for (final install in installations)
                  if (install.agentId == row.agentId) install,
              ],
            ),
        ],
      ],
    );
  }
}
