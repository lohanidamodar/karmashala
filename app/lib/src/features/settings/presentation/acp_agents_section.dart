import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../agents/application/acp_agent_providers.dart';
import 'acp_agent_dialog.dart';
import 'settings_section.dart';
import 'settings_theme.dart';

/// Settings → Agents and accounts → ACP agents: the agents a person added —
/// from the public registry or by hand — each with the command that starts
/// it, editable and removable, and the button that adds one.
class AcpAgentsSection extends ConsumerWidget {
  const AcpAgentsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(acpAgentRowsProvider);
    final setup = ref.watch(acpAgentsSetupProvider);
    final theme = Theme.of(context);
    return SettingsSection(
      title: 'ACP AGENTS',
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
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
          else
            for (final row in rows) _AcpAgentEntry(row: row),
        ],
      ),
    );
  }
}

class _AcpAgentEntry extends ConsumerWidget {
  const _AcpAgentEntry({required this.row});

  final AcpAgentRow row;

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
    return SettingsCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        row.name,
                        style: SettingsStyles.rowLabel(context),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: Insets.sm),
                    _SourceChip(source: row.source),
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
    );
  }
}

/// Registry or Custom, as a quiet pill beside the name.
class _SourceChip extends StatelessWidget {
  const _SourceChip({required this.source});

  final AcpAgentSource source;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Insets.sm, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Text(
        switch (source) {
          AcpAgentSource.registry => 'Registry',
          AcpAgentSource.custom => 'Custom',
        },
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: scheme.onSecondaryContainer),
      ),
    );
  }
}
