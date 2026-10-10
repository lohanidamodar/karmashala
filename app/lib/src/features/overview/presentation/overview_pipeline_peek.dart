import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../explorer/application/agent_state_providers.dart'
    show workspaceSessionsProvider;
import '../../pipelines/application/pipelines_controller.dart';
import '../../pipelines/presentation/pipeline_run_card.dart';
import '../../pipelines/presentation/pipeline_run_detail.dart';
import '../../pipelines/presentation/pipeline_words.dart';
import '../application/overview_pipeline_peek.dart';
import 'overview_peek.dart' show overviewPeekChatProvider;

/// **A pipeline run's peek**: round 80's run — every stage with its state,
/// agent and time, the gate's Approve, Edit hand-off and Stop, and each
/// stage's answer, artifacts and hand-off — beside the board, or a phone's
/// page. A stage clicked shows its session's chat here, with a way back.
class PipelineRunPeek extends ConsumerWidget {
  const PipelineRunPeek({
    required this.peek,
    required this.onClose,
    this.compact = false,
    super.key,
  });

  final PipelinePeek peek;
  final VoidCallback onClose;

  /// A phone's page: its close is a back arrow.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final run = ref.watch(pipelinesProvider.select((s) => s.runs[peek.runId]));
    final controller = ref.read(pipelinePeekProvider.notifier);
    final stage = peek.stageSessionId;
    final record = stage == null || run == null
        ? null
        : run.records.lastWhere(
            (r) => r.sessionId == stage,
            orElse: () => run.records.last,
          );
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(
        Insets.xs,
        Insets.xs,
        Insets.xs,
        Insets.xs,
      ),
      child: Row(
        children: [
          if (stage != null)
            IconButton(
              key: const ValueKey('pipeline-peek-back'),
              tooltip: 'Back to the run',
              icon: const Icon(AppIcons.arrowLeft),
              onPressed: controller.backToRun,
            )
          else if (compact)
            IconButton(
              key: const ValueKey('pipeline-peek-close'),
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              icon: const Icon(AppIcons.arrowLeft),
              onPressed: onClose,
            )
          else
            const Padding(
              padding: EdgeInsets.all(Insets.sm),
              child: Icon(AppIcons.treeStructure, size: Chrome.icon),
            ),
          const SizedBox(width: Insets.xxs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  stage == null
                      ? run?.definition.name ?? 'Pipeline run'
                      : record?.role ?? 'Stage',
                  key: const ValueKey('pipeline-peek-title'),
                  style: theme.textTheme.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (run != null)
                  Text(
                    stage == null
                        ? pipelineRunStateLabel(run)
                        : '${run.definition.name} · '
                              '${pipelineStageStateLabel(record?.state)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          if (!compact || stage != null)
            IconButton(
              key: const ValueKey('pipeline-peek-close-x'),
              tooltip: 'Close',
              icon: const Icon(AppIcons.x),
              onPressed: onClose,
            ),
        ],
      ),
    );
    final Widget body;
    if (run == null) {
      body = const PanePlaceholder(
        icon: AppIcons.treeStructure,
        message: 'This run is no longer listed.',
      );
    } else if (stage != null) {
      final entry = ref
          .watch(workspaceSessionsProvider)
          .where((e) => e.id == stage)
          .firstOrNull;
      body = entry == null
          ? const PanePlaceholder(
              icon: AppIcons.chat,
              message: 'This stage\'s session is not on this machine.',
            )
          : ref.watch(overviewPeekChatProvider)(entry, null);
    } else {
      body = PipelineRunDetail(
        key: ValueKey('pipeline-peek-detail:${run.id}'),
        runId: run.id,
        onOpenSession: (id) => controller.openStage(run.id, id),
        header: Padding(
          padding: const EdgeInsets.only(top: Insets.sm),
          child: PipelineRunCard(
            run: run,
            showDetails: false,
            onOpenStage: (id) => controller.openStage(run.id, id),
          ),
        ),
      );
    }
    return Material(
      key: ValueKey('pipeline-peek:${peek.runId}'),
      color: theme.colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          const Divider(height: 1),
          Expanded(
            child: KeyedSubtree(
              key: ValueKey('pipeline-peek-body:${stage ?? 'run'}'),
              child: body,
            ),
          ),
        ],
      ),
    );
  }
}
