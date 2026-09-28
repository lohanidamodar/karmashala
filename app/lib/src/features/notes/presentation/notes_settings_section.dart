import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/application/settings_controller.dart';
import '../../settings/presentation/settings_row.dart';
import '../../settings/presentation/settings_section.dart';
import '../application/notes_providers.dart';

/// Settings → General → Notes: the one switch that decides whether the feature
/// is there.
class NotesSettingsSection extends ConsumerWidget {
  const NotesSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(notesEnabledProvider);
    final kept = ref.watch(notesProvider).length;
    final controller = ref.read(settingsControllerProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSection(
          title: 'NOTES',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SettingsSwitchRow(
                label: 'Notes',
                help:
                    'Adds a note button under any message, and a Notes panel.',
                value: enabled,
                onChanged: controller.setNotesEnabled,
              ),
              // Said on the page rather than in a confirmation, because the
              // fear this answers ("will I lose them?") arrives before the
              // switch is touched, not after.
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  enabled
                      ? 'Turning this off hides the button and the panel. '
                            'Nothing you have saved is deleted.'
                      : kept == 0
                      ? 'Hidden. You have no saved notes.'
                      : 'Hidden. Your $kept saved note'
                            '${kept == 1 ? '' : 's'} '
                            '${kept == 1 ? 'is' : 'are'} still here and comes '
                            'back when you turn this on.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
