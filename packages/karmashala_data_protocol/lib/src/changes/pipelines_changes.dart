part of '../data_change.dart';

// Pipelines and their runs.

DataChange? _pipelinesChangeFromJson(
  String name,
  Map<String, Object?> json,
) => switch (name) {
  'pipelineChanged' => PipelineChanged(PipelineDefinition.fromJson(_row(json))),
  'pipelineRemoved' => PipelineRemoved(json['id']! as String),
  'pipelineRunChanged' => PipelineRunChanged(PipelineRun.fromJson(_row(json))),
  _ => null,
};

/// A change to a saved pipeline or a run.
sealed class PipelinesChange extends DataChange {
  const PipelinesChange();
}

final class PipelineChanged extends PipelinesChange {
  const PipelineChanged(this.pipeline);

  final PipelineDefinition pipeline;

  @override
  Map<String, Object?> toJson() => {
    'change': 'pipelineChanged',
    'row': pipeline.toJson(),
  };
}

final class PipelineRemoved extends PipelinesChange {
  const PipelineRemoved(this.id);

  final String id;

  @override
  Map<String, Object?> toJson() => {'change': 'pipelineRemoved', 'id': id};
}

/// A run started, moved on a stage, waited at a gate, or ended.
final class PipelineRunChanged extends PipelinesChange {
  const PipelineRunChanged(this.run);

  final PipelineRun run;

  @override
  Map<String, Object?> toJson() => {
    'change': 'pipelineRunChanged',
    'row': run.toJson(),
  };
}
