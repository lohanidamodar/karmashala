import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_automations/pipelines.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/shell/phone_shell.dart' show phoneWorkbenchOpener;
import '../../../app/widgets/adaptive_modal.dart';
import '../../explorer/application/explorer_actions.dart';
import '../application/pipelines_controller.dart';
import 'pipeline_run_card.dart';
import 'pipeline_words.dart';

/// A run's detail: each stage attempt's answer, artifacts, checks and its
/// session, kept current as the run moves.
Future<void> showPipelineRunDetail(BuildContext context, String runId) {
  final run = ProviderScope.containerOf(
    context,
  ).read(pipelinesProvider).runs[runId];
  return showAdaptiveModal<void>(
    context: context,
    title: run?.definition.name ?? 'Pipeline run',
    width: DialogWidth.wide,
    heightFactor: 0.85,
    builder: (_) => PipelineRunDetail(runId: runId),
  );
}

/// Every recent run, newest first, each as its card.
Future<void> showPipelineRuns(BuildContext context) => showAdaptiveModal<void>(
  context: context,
  title: 'Pipeline runs',
  width: DialogWidth.wide,
  heightFactor: 0.85,
  builder: (_) => const _PipelineRunList(),
);

class _PipelineRunList extends ConsumerWidget {
  const _PipelineRunList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final runs = ref.watch(pipelinesProvider).runsNewestFirst;
    if (runs.isEmpty) {
      return const Center(child: Text('No pipeline has run yet.'));
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
      itemCount: runs.length,
      separatorBuilder: (_, _) => const SizedBox(height: Insets.sm),
      itemBuilder: (_, i) => PipelineRunCard(run: runs[i]),
    );
  }
}

class PipelineRunDetail extends ConsumerWidget {
  const PipelineRunDetail({required this.runId, super.key});

  final String runId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final run = ref.watch(pipelinesProvider.select((s) => s.runs[runId]));
    final theme = Theme.of(context);
    if (run == null) {
      return const Center(child: Text('This run is no longer listed.'));
    }
    return ListView(
      key: ValueKey('pipeline-detail:$runId'),
      padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
      children: [
        Text(pipelineRunStateLabel(run), style: theme.textTheme.titleSmall),
        const SizedBox(height: Insets.xs),
        SelectableText(run.input, style: theme.textTheme.bodySmall),
        if (run.reason case final reason?) ...[
          const SizedBox(height: Insets.xs),
          SelectableText(
            reason,
            style: theme.textTheme.bodySmall?.copyWith(
              color: SemanticColors.of(context).failure,
            ),
          ),
        ],
        const SizedBox(height: Insets.md),
        if (run.records.isEmpty) const Text('No stage has started yet.'),
        for (final record in run.records) ...[
          _StageRecord(record: record),
          const Divider(height: Insets.lg),
        ],
      ],
    );
  }
}

class _StageRecord extends ConsumerWidget {
  const _StageRecord({required this.record});

  final PipelineStageRecord record;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall;
    final muted = small?.copyWith(color: scheme.onSurfaceVariant);
    final check = record.check;
    final session = record.sessionId;
    return Column(
      key: ValueKey('pipeline-record:${record.stageIndex}:${record.attempt}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(
              pipelineStageIcon(record.state),
              size: Chrome.icon,
              color: pipelineStageColor(context, record.state),
            ),
            const SizedBox(width: Insets.xs),
            Expanded(
              child: Text(
                '${record.role}'
                '${record.attempt > 1 ? ' · try ${record.attempt}' : ''}',
                style: theme.textTheme.titleSmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              '${pipelineStageStateLabel(record.state)} · '
              '${pipelineDuration(record.duration)}',
              style: muted,
            ),
          ],
        ),
        if (session != null)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: ValueKey('pipeline-open-session:$session'),
              onPressed: () => unawaited(_openSession(context, ref, session)),
              icon: const Icon(AppIcons.arrowUpRight),
              label: const Text('Open session'),
            ),
          ),
        if (record.worktreePath != null)
          Text(
            'Worktree ${record.worktreePath}'
            '${record.branch == null ? '' : ' · branch ${record.branch}'}',
            style: muted,
          ),
        if (record.artifacts.isNotEmpty) ...[
          const SizedBox(height: Insets.xs),
          Wrap(
            spacing: Insets.xs,
            runSpacing: Insets.xs,
            children: [
              for (final artifact in record.artifacts)
                Chip(
                  visualDensity: VisualDensity.compact,
                  avatar: const Icon(AppIcons.file, size: Chrome.iconSmall),
                  label: Text(artifact.title),
                ),
            ],
          ),
        ],
        if (check != null) ...[
          const SizedBox(height: Insets.xs),
          Text(
            'Checks ${check.label}'
            '${check.identity == null ? '' : ' on ${check.identity!.label}'}',
            style: small?.copyWith(
              color: check.passed
                  ? SemanticColors.of(context).idle
                  : SemanticColors.of(context).failure,
            ),
          ),
          if (check.summary.isNotEmpty) _Block(check.summary),
        ],
        if (record.handoff != null) ...[
          const SizedBox(height: Insets.xs),
          Text('Hand-off, as approved', style: muted),
          _Block(record.handoff!),
        ],
        if ((record.answer ?? '').isNotEmpty) ...[
          const SizedBox(height: Insets.xs),
          Text('Answer', style: muted),
          _Block(record.answer!),
        ],
        if (record.reason != null &&
            record.state != PipelineStageState.done) ...[
          const SizedBox(height: Insets.xs),
          Text('Why', style: muted),
          _Block(record.reason!),
        ],
      ],
    );
  }

  static Future<void> _openSession(
    BuildContext context,
    WidgetRef ref,
    String sessionId,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final showWorkbench = phoneWorkbenchOpener(context, ref);
    final result = await ref
        .read(explorerActionsProvider)
        .openNative(sessionId);
    if (!result.isFailure) showWorkbench?.call();
    if (result.message != null) {
      messenger?.showSnackBar(SnackBar(content: Text(result.message!)));
    }
  }
}

/// A long text, its own scroll past a few lines.
class _Block extends StatelessWidget {
  const _Block(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(top: Insets.xxs),
      padding: const EdgeInsets.all(Insets.sm),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.3,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: SingleChildScrollView(
        child: SelectableText(text, style: theme.textTheme.bodySmall),
      ),
    );
  }
}
