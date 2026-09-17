import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/presentation/settings_catalog.dart';
import '../../settings/presentation/settings_row.dart';
import '../../settings/presentation/settings_section.dart';
import '../application/checkpoint_settings.dart';

/// Settings → Agents → Checkpoints: whether every turn is checkpointed, and
/// how many checkpoints each repository keeps.
class CheckpointSettingsSection extends ConsumerWidget {
  const CheckpointSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(checkpointSettingsProvider);
    final controller = ref.read(checkpointSettingsProvider.notifier);
    return SettingsSection(
      title: SettingsAnchor.checkpoints.heading,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsSwitchRow(
            label: 'Automatic checkpoints',
            help:
                'Every turn: a snapshot of each repository an agent works in '
                'as its turn starts and as it ends, for every agent. Restoring '
                'one puts files back; the agent’s conversation is not '
                'rewound. Off: only Capture now and checkpoint_capture.',
            value: settings.automatic,
            onChanged: controller.setAutomatic,
          ),
          SettingsRow(
            label: 'Keep per repository',
            help:
                'The newest checkpoints a session keeps of each repository. '
                'Older ones are dropped and their git objects become '
                'collectable.',
            control: DropdownButtonFormField<int?>(
              initialValue:
                  kCheckpointRetentionChoices.contains(
                    settings.keepPerRepository,
                  )
                  ? settings.keepPerRepository
                  : kDefaultCheckpointRetention,
              isExpanded: true,
              items: [
                for (final keep in kCheckpointRetentionChoices)
                  DropdownMenuItem(
                    value: keep,
                    child: Text(keep == null ? 'All of them' : 'Newest $keep'),
                  ),
              ],
              onChanged: controller.setKeepPerRepository,
            ),
          ),
        ],
      ),
    );
  }
}
