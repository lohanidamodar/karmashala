import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../agents/application/acp_agent_providers.dart';
import 'acp_agent_dialog.dart';
import 'acp_builtin_agent_row.dart' show acpAgentsNote;
import 'agent_health.dart';
import 'environment_chips.dart';
import 'settings_row.dart';
import 'settings_theme.dart';

/// **An ACP agent a person added, one row**: its name, where it came from
/// (Registry or Custom), the machines it was found on, the command that
/// starts it, and Edit and Remove. Nothing a terminal agent's row has that
/// an ACP agent cannot answer — no version, no account, no mode.
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
    final health = readAgentHealth(ref, installs: installs);
    return SettingsRuled(
      child: Tooltip(
        message: acpAgentsNote,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2, right: Insets.sm),
              child: AgentHealthGlyph(reading: health),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: Insets.sm,
                    runSpacing: Insets.xs,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(row.name, style: SettingsStyles.rowLabel(context)),
                      SettingsChip(
                        label: switch (row.source) {
                          AcpAgentSource.registry => 'Registry',
                          AcpAgentSource.custom => 'Custom',
                        },
                      ),
                      EnvironmentChips(
                        environmentIds: installs.map((i) => i.environmentId),
                      ),
                    ],
                  ),
                  const SizedBox(height: Insets.xs),
                  Text(
                    [row.command, ...row.args].join(' '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: MonoStyles.small.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
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
      ),
    );
  }
}
