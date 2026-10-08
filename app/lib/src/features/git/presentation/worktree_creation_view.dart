import 'package:flutter/material.dart';

import 'package:karmashala_git/git.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_git/worktrees.dart';

/// A creation in flight, redrawn on every stage change the tracker publishes.
class WorktreeCreationLiveView extends StatelessWidget {
  const WorktreeCreationLiveView({required this.tracker, super.key});

  final WorktreeCreationTracker tracker;

  @override
  Widget build(BuildContext context) => StreamBuilder<WorktreeCreationRecord>(
    stream: tracker.changes,
    initialData: tracker.record,
    builder: (context, snapshot) =>
        WorktreeStageList(record: snapshot.data ?? tracker.record),
  );
}

/// Every stage of one creation: its state, git's percentage while it runs,
/// and — for a stage that failed or warned — the tail of what it printed.
class WorktreeStageList extends StatelessWidget {
  const WorktreeStageList({
    required this.record,
    this.showSkipped = true,
    super.key,
  });

  final WorktreeCreationRecord record;

  /// A summary line in a list has no room for stages that did nothing.
  final bool showSkipped;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final status in record.stages)
          if (showSkipped || status.state != WorktreeStageState.skipped)
            _StageRow(key: ValueKey(status.stage), status: status),
        if (record.cleanup != null)
          Padding(
            padding: const EdgeInsets.only(top: Insets.xs),
            child: Text(record.cleanup!, style: theme.textTheme.bodySmall),
          ),
      ],
    );
  }
}

class _StageRow extends StatelessWidget {
  const _StageRow({required this.status, super.key});

  final WorktreeStageStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final state = status.state;
    final colour = switch (state) {
      WorktreeStageState.failed => scheme.error,
      WorktreeStageState.warning => scheme.tertiary,
      WorktreeStageState.pending ||
      WorktreeStageState.skipped => scheme.onSurfaceVariant,
      _ => scheme.onSurface,
    };
    final running = state == WorktreeStageState.running;
    final percent = status.percent;
    final showTail =
        status.outputTail.isNotEmpty &&
        (state == WorktreeStageState.failed ||
            state == WorktreeStageState.warning);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.xxs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: Chrome.iconSmall,
                height: Chrome.iconSmall,
                child: running
                    ? const InlineSpinner()
                    : Icon(
                        _iconFor(state),
                        size: Chrome.iconSmall,
                        color: colour,
                      ),
              ),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Text(
                  // The state in words too: colour alone is not a signal.
                  '${status.stage.label} · ${_stateWord(state)}'
                  '${running && percent != null ? ' · ${status.progressLabel ?? ''} $percent%' : ''}',
                  style: theme.textTheme.bodySmall?.copyWith(color: colour),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (running && percent != null)
            Padding(
              padding: const EdgeInsets.only(
                left: Insets.xl - Insets.xxs,
                top: Insets.xxs,
              ),
              child: LinearProgressIndicator(value: percent / 100),
            ),
          if (status.detail != null && status.detail!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(
                left: Insets.xl - Insets.xxs,
                top: Insets.hair,
              ),
              child: Text(status.detail!, style: theme.textTheme.bodySmall),
            ),
          if (showTail)
            Container(
              margin: const EdgeInsets.only(
                left: Insets.xl - Insets.xxs,
                top: Insets.xs,
              ),
              padding: const EdgeInsets.all(Insets.sm),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: SelectableText(
                status.outputTail.join('\n'),
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: kMonoFamily,
                  fontFamilyFallback: kMonoFallback,
                ),
              ),
            ),
        ],
      ),
    );
  }

  static IconData _iconFor(WorktreeStageState state) => switch (state) {
    WorktreeStageState.pending => AppIcons.circle,
    WorktreeStageState.running => AppIcons.circle,
    WorktreeStageState.done => AppIcons.checkCircle,
    WorktreeStageState.skipped => AppIcons.minusCircle,
    WorktreeStageState.warning => AppIcons.warning,
    WorktreeStageState.failed => AppIcons.xCircle,
  };

  static String _stateWord(WorktreeStageState state) => switch (state) {
    WorktreeStageState.pending => 'waiting',
    WorktreeStageState.running => 'running',
    WorktreeStageState.done => 'done',
    WorktreeStageState.skipped => 'skipped',
    WorktreeStageState.warning => 'needs attention',
    WorktreeStageState.failed => 'failed',
  };
}

/// How a whole creation ended, in a few words.
String describeWorktreeOutcome(WorktreeCreationOutcome outcome) =>
    switch (outcome) {
      WorktreeCreationOutcome.running => 'still running',
      WorktreeCreationOutcome.succeeded => 'created',
      WorktreeCreationOutcome.warning => 'created, needs attention',
      WorktreeCreationOutcome.failed => 'failed, not created',
      WorktreeCreationOutcome.cancelled => 'cancelled',
    };
