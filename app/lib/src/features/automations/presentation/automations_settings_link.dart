import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/workbench_tabs.dart' show openAutomationsTab;
import '../../settings/presentation/settings_catalog.dart';
import '../../settings/presentation/settings_row.dart';
import '../../settings/presentation/settings_section.dart';
import 'automations_tab_state.dart';

/// What Settings keeps of automations: where they are now. Searching
/// Settings for an automation, a webhook or a schedule lands here.
class AutomationsSettingsLink extends ConsumerWidget {
  const AutomationsSettingsLink({
    required this.anchor,
    required this.section,
    super.key,
  });

  final SettingsAnchor anchor;
  final AutomationsSection section;

  @override
  Widget build(BuildContext context, WidgetRef ref) => SettingsSection(
    title: anchor.heading,
    child: SettingsRow(
      label: switch (section) {
        AutomationsSection.resumes =>
          'Scheduled resumes, and what happens at a usage limit',
        _ => 'Automations, webhooks and their runs',
      },
      help: 'They have their own tab, Automations.',
      control: FilledButton.tonal(
        key: ValueKey('open-automations-${section.name}'),
        onPressed: () => openAutomationsTab(ref, section: section),
        child: const Text('Open Automations'),
      ),
    ),
  );
}
