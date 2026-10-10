import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../automations/application/automation_draft.dart';
import '../../automations/application/automation_editor_state.dart';
import '../../automations/application/automation_providers.dart';
import '../../automations/presentation/automations_list_view.dart';
import '../application/workflows_state.dart';
import 'pipelines_grid_view.dart';
import 'workflow_runs_view.dart';

export '../application/workflows_state.dart';

/// The page's name, where the tab, More and the header say it.
const String kWorkflowsTitle = 'Workflows';

/// **Workflows**: automations — the sessions waiting to be resumed under
/// them — pipelines, and every run of both, one section at a time. Built only while its tab is
/// on screen; on the phone it is a page under More.
class WorkflowsTabView extends ConsumerWidget {
  const WorkflowsTabView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final section = ref.watch(workflowsSectionProvider);
    return WorkbenchTabScaffold(
      icon: AppIcons.flowArrow,
      title: kWorkflowsTitle,
      controls: [
        CompactSegmented<WorkflowsSection>(
          key: const ValueKey('workflows-section'),
          tight: WidthClass.of(MediaQuery.sizeOf(context).width).isCompact,
          segments: [
            for (final value in WorkflowsSection.values)
              ButtonSegment(
                value: value,
                // Beside a phone's back arrow three names do not fit at
                // their size: a label shrinks, its target does not.
                label: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    value.label,
                    key: ValueKey('workflows-section:${value.name}'),
                    maxLines: 1,
                    softWrap: false,
                  ),
                ),
              ),
          ],
          selected: section,
          onChanged: ref.read(workflowsSectionProvider.notifier).show,
        ),
      ],
      actions: [
        switch (section) {
          WorkflowsSection.automations => IconButton(
            key: const ValueKey('automation-new'),
            tooltip: 'New automation',
            icon: const Icon(AppIcons.plus),
            onPressed: () => ref
                .read(automationEditorProvider.notifier)
                .open(
                  AutomationDraft(
                    repositoryId: ref
                        .read(automationCheckoutsProvider)
                        .firstOrNull
                        ?.id,
                  ),
                ),
          ),
          WorkflowsSection.pipelines => IconButton(
            key: const ValueKey('pipeline-new'),
            tooltip: 'New pipeline',
            icon: const Icon(AppIcons.plus),
            onPressed: () => ref.read(pipelineEditingProvider.notifier).open(),
          ),
          WorkflowsSection.runs => const WorkflowRunsFilterButton(),
        },
      ],
      body: switch (section) {
        WorkflowsSection.automations => const AutomationsListView(),
        WorkflowsSection.pipelines => const PipelinesGridView(),
        WorkflowsSection.runs => const WorkflowRunsView(),
      },
    );
  }
}

/// Whether a list or grid of [width] has room for a [Chrome.detailPaneWidth]
/// pane beside it, at the text scale: the grid keeps a card's width.
bool hasRoomForDetailPane(double width, TextScaler scaler) =>
    width >=
    WidthClass.scaleBreakpoint(
      Chrome.detailPaneWidth + kAutomationCardMinWidth + Insets.xl,
      scaler,
    );

/// [main], with [detail] beside it in a pane when there is room, or instead
/// of it when there is not.
class ListWithDetail extends StatelessWidget {
  const ListWithDetail({required this.main, this.detail, super.key});

  final Widget main;
  final Widget? detail;

  @override
  Widget build(BuildContext context) {
    final detail = this.detail;
    if (detail == null) return main;
    return LayoutBuilder(
      builder: (context, constraints) {
        final scaler = MediaQuery.textScalerOf(context);
        if (!hasRoomForDetailPane(constraints.maxWidth, scaler)) return detail;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: main),
            const VerticalDivider(width: 1),
            SizedBox(
              width: scaler.scale(Chrome.detailPaneWidth),
              child: detail,
            ),
          ],
        );
      },
    );
  }
}
