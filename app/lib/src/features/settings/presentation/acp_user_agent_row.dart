import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/util/clock_provider.dart';
import '../../agents/application/acp_agent_providers.dart';
import '../../agents/presentation/agent_logo.dart';
import '../../agents/presentation/agent_version_label.dart';
import 'acp_agent_dialog.dart';
import 'acp_builtin_agent_row.dart' show acpAgentsNote;
import 'acp_login_lines.dart';
import 'agent_collapsed_row.dart';
import 'agent_health.dart';
import 'environment_chips.dart';

/// **An ACP agent a person added, one row**: its name, where it came from
/// (Registry or Custom), the machines it was found on, the command that
/// starts it, the version it reported of itself over ACP, its login per
/// machine, and Edit and Remove. Nothing a terminal agent's row has that an
/// ACP agent cannot answer — no account, no mode.
class AcpUserAgentRow extends ConsumerWidget {
  const AcpUserAgentRow({required this.row, required this.installs, super.key});

  final AcpAgentRow row;
  final List<AgentInstallation> installs;

  Future<void> _remove(BuildContext context, WidgetRef ref) async {
    final setup = ref.read(acpAgentsSetupProvider.notifier);
    final confirmed = await showConfirmDialog(
      context,
      title: 'Remove ${row.name}?',
      message:
          'Karmashala forgets how to start it. Sessions already recorded '
          'with it stay.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (confirmed) await setup.remove(row.id);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return AgentCollapsedRow(
      name: row.name,
      logo: AgentLogo(agentId: row.agentId, size: Chrome.iconAction),
      tags: [
        SettingsChip(
          label: switch (row.source) {
            AcpAgentSource.registry => 'Registry',
            AcpAgentSource.custom => 'Custom',
          },
        ),
      ],
      health: readAgentHealth(ref, installs: installs),
      environmentIds: installs.map((i) => i.environmentId),
      tooltip: acpAgentsNote,
      detail: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [row.command, ...row.args].join(' '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: MonoStyles.small.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (installs.isNotEmpty) ...[
            const SizedBox(height: Insets.xs),
            Text(
              describeAgentVersions(
                installs,
                now: ref.watch(clockProvider).nowUtc(),
              ),
            ),
            AcpLoginLines(installs: installs, agentName: row.name),
          ],
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Edit ${row.name}',
            icon: const Icon(AppIcons.pencil, size: Chrome.iconAction),
            onPressed: () => AcpAgentDialog.show(context, existing: row),
          ),
          IconButton(
            tooltip: 'Remove ${row.name}',
            icon: const Icon(AppIcons.trash, size: Chrome.iconAction),
            onPressed: () => _remove(context, ref),
          ),
        ],
      ),
    );
  }
}
