import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/workbench_tabs.dart' show openWorkflowsTab;
import '../../settings/presentation/settings_catalog.dart';
import '../../settings/presentation/settings_row.dart';
import '../../settings/presentation/settings_section.dart';
import '../../workflows/application/workflows_state.dart';

/// What Settings keeps of automations: where they are now. Searching
/// Settings for an automation, a webhook or a schedule lands here.
class AutomationsSettingsLink extends ConsumerWidget {
  const AutomationsSettingsLink({
    required this.anchor,
    required this.section,
    super.key,
  });

  final SettingsAnchor anchor;
  final WorkflowsSection section;

  @override
  Widget build(BuildContext context, WidgetRef ref) => SettingsSection(
    title: anchor.heading,
    child: SettingsRow(
      label:
          'Automations, pipelines, webhooks, runs, checks and scheduled '
          'resumes',
      help: 'They have their own page, Workflows.',
      control: FilledButton.tonal(
        key: ValueKey('open-workflows-${section.name}'),
        onPressed: () => openWorkflowsTab(ref, section: section),
        child: const Text('Open Workflows'),
      ),
    ),
  );
}
