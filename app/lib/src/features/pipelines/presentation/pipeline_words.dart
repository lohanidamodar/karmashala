import 'package:flutter/material.dart';
import 'package:karmashala_automations/pipelines.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

/// What a run's state says in a line.
String pipelineRunStateLabel(PipelineRun run) {
  final current = run.current;
  return switch (run.state) {
    PipelineRunState.running => switch (current?.state) {
      PipelineStageState.checking => 'Checking ${current!.role}',
      null => 'Starting',
      _ => 'Running ${current!.role}',
    },
    PipelineRunState.waiting =>
      'Waiting for you at ${current?.role ?? 'a gate'}',
    PipelineRunState.finished => 'Finished',
    PipelineRunState.failed => 'Failed at ${current?.role ?? 'the start'}',
    PipelineRunState.stopped => 'Stopped at ${current?.role ?? 'the start'}',
  };
}

String pipelineStageStateLabel(PipelineStageState? state) => switch (state) {
  null => 'Not started',
  PipelineStageState.starting => 'Starting',
  PipelineStageState.running => 'Running',
  PipelineStageState.checking => 'Checking',
  PipelineStageState.approval => 'Needs your approval',
  PipelineStageState.done => 'Done',
  PipelineStageState.failed => 'Failed',
  PipelineStageState.skipped => 'Skipped',
  PipelineStageState.stopped => 'Stopped',
  PipelineStageState.loopedBack => 'Sent back',
};

IconData pipelineStageIcon(PipelineStageState? state) => switch (state) {
  null => AppIcons.clock,
  PipelineStageState.starting ||
  PipelineStageState.running ||
  PipelineStageState.checking => AppIcons.playCircle,
  PipelineStageState.approval => AppIcons.warningCircle,
  PipelineStageState.done => AppIcons.checkCircle,
  PipelineStageState.failed => AppIcons.xCircle,
  PipelineStageState.skipped => AppIcons.arrowBendDownRight,
  PipelineStageState.stopped => AppIcons.stopCircle,
  PipelineStageState.loopedBack => AppIcons.arrowCounterClockwise,
};

Color pipelineStageColor(BuildContext context, PipelineStageState? state) {
  final semantic = SemanticColors.of(context);
  return switch (state) {
    null ||
    PipelineStageState.skipped ||
    PipelineStageState.stopped => semantic.neutral,
    PipelineStageState.starting ||
    PipelineStageState.running ||
    PipelineStageState.checking => semantic.working,
    PipelineStageState.approval ||
    PipelineStageState.loopedBack => semantic.attention,
    PipelineStageState.done => semantic.idle,
    PipelineStageState.failed => semantic.failure,
  };
}

/// `42s`, `3m 12s`, `1h 5m`.
String pipelineDuration(Duration? duration) {
  if (duration == null) return '—';
  final seconds = duration.inSeconds;
  if (seconds < 60) return '${seconds}s';
  final minutes = duration.inMinutes;
  if (minutes < 60) return '${minutes}m ${seconds % 60}s';
  return '${duration.inHours}h ${minutes % 60}m';
}
