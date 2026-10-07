import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import 'automation_runs_view.dart';
import 'automations_page.dart';
import 'automations_tab_state.dart';
import 'scheduled_resumes_section.dart';

export 'automations_tab_state.dart';

/// **The Automations tab**: every automation, every run, and the sessions
/// waiting to be resumed. Built only while its tab is on screen; on the phone
/// it is a page under More.
class AutomationsTabView extends ConsumerWidget {
  const AutomationsTabView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final section = ref.watch(automationsSectionProvider);
    return WorkbenchTabScaffold(
      icon: AppIcons.lightning,
      title: 'Automations',
      controls: [
        CompactSegmented<AutomationsSection>(
          key: const ValueKey('automations-section'),
          segments: [
            for (final value in AutomationsSection.values)
              ButtonSegment(value: value, label: Text(value.label)),
          ],
          selected: section,
          onChanged: ref.read(automationsSectionProvider.notifier).show,
        ),
      ],
      body: switch (section) {
        AutomationsSection.automations => const _Readable(
          child: AutomationsPage(),
        ),
        AutomationsSection.runs => const AutomationRunsView(),
        AutomationsSection.resumes => const _Readable(
          child: ScheduledResumesSection(),
        ),
      },
    );
  }
}

/// A scrolling column no wider than reads well.
class _Readable extends StatelessWidget {
  const _Readable({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.all(Insets.lg),
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: Chrome.readableWidth),
        child: child,
      ),
    ),
  );
}
