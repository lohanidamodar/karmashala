part of '../data_request.dart';

// Pipelines: saved definitions and their runs, driven by the server.

DataRequest<Object?>? _pipelinesRequestFromJson(String kind, _Arguments args) =>
    switch (kind) {
      PipelinesList.name => const PipelinesList(),
      PipelineSave.name => PipelineSave(
        args.value('pipeline', PipelineDefinition.fromJson),
      ),
      PipelineDelete.name => PipelineDelete(args.string('id')),
      PipelineRunStart.name => PipelineRunStart(
        definition: args.value('definition', PipelineDefinition.fromJson),
        repositoryId: args.string('repositoryId'),
        input: args.string('input'),
      ),
      PipelineRunApprove.name => PipelineRunApprove(
        args.string('runId'),
        handoff: args.optionalString('handoff'),
      ),
      PipelineRunStop.name => PipelineRunStop(args.string('runId')),
      PipelineRunRetry.name => PipelineRunRetry(args.string('runId')),
      PipelineRunSkip.name => PipelineRunSkip(args.string('runId')),
      _ => null,
    };

/// A request about pipelines. Answered when the server's runner has acted.
sealed class PipelinesRequest<R> extends DataRequest<R> {
  const PipelinesRequest();
}

/// How many recent runs [PipelinesList] answers with.
const int kPipelineRunsListed = 30;

/// The built-in templates, the saved pipelines and the recent runs.
class PipelinesSnapshot {
  const PipelinesSnapshot({
    required this.templates,
    required this.saved,
    required this.runs,
  });

  final List<PipelineDefinition> templates;
  final List<PipelineDefinition> saved;

  /// Newest first.
  final List<PipelineRun> runs;

  Map<String, Object?> toJson() => {
    'templates': [for (final t in templates) t.toJson()],
    'saved': [for (final s in saved) s.toJson()],
    'runs': [for (final r in runs) r.toJson()],
  };

  static PipelinesSnapshot fromJson(Map<String, Object?> json) =>
      PipelinesSnapshot(
        templates: [
          for (final t in json['templates']! as List<Object?>)
            PipelineDefinition.fromJson((t! as Map).cast<String, Object?>()),
        ],
        saved: [
          for (final s in json['saved']! as List<Object?>)
            PipelineDefinition.fromJson((s! as Map).cast<String, Object?>()),
        ],
        runs: [
          for (final r in json['runs']! as List<Object?>)
            PipelineRun.fromJson((r! as Map).cast<String, Object?>()),
        ],
      );
}

final class PipelinesList extends PipelinesRequest<PipelinesSnapshot> {
  const PipelinesList();

  static const String name = 'pipelines.list';

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => const {};

  @override
  Object? resultToJson(PipelinesSnapshot result) => result.toJson();

  @override
  PipelinesSnapshot resultFromJson(Object? json) =>
      _decode(kind, () => PipelinesSnapshot.fromJson(_object(json, kind)));
}

/// Saves [pipeline] under its id; refused when it cannot run. Answers it as
/// stored.
final class PipelineSave extends PipelinesRequest<PipelineDefinition> {
  const PipelineSave(this.pipeline);

  static const String name = 'pipelines.save';

  final PipelineDefinition pipeline;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'pipeline': pipeline.toJson()};

  @override
  Object? resultToJson(PipelineDefinition result) => result.toJson();

  @override
  PipelineDefinition resultFromJson(Object? json) =>
      _decode(kind, () => PipelineDefinition.fromJson(_object(json, kind)));
}

final class PipelineDelete extends PipelinesRequest<DataAck> {
  const PipelineDelete(this.id);

  static const String name = 'pipelines.delete';

  final String id;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id};

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}

/// A request that acts on a run and answers it as it now is.
sealed class _PipelineRunAnswer extends PipelinesRequest<PipelineRun> {
  const _PipelineRunAnswer();

  @override
  Object? resultToJson(PipelineRun result) => result.toJson();

  @override
  PipelineRun resultFromJson(Object? json) =>
      _decode(kind, () => PipelineRun.fromJson(_object(json, kind)));
}

/// Starts [definition] on [repositoryId] with [input], as a person's run.
final class PipelineRunStart extends _PipelineRunAnswer {
  const PipelineRunStart({
    required this.definition,
    required this.repositoryId,
    required this.input,
  });

  static const String name = 'pipelineRuns.start';

  final PipelineDefinition definition;
  final String repositoryId;
  final String input;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'definition': definition.toJson(),
    'repositoryId': repositoryId,
    'input': input,
  };
}

/// Approves the hand-off [runId] waits on, as [handoff] when edited.
final class PipelineRunApprove extends _PipelineRunAnswer {
  const PipelineRunApprove(this.runId, {this.handoff});

  static const String name = 'pipelineRuns.approve';

  final String runId;
  final String? handoff;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'runId': runId,
    'handoff': ?handoff,
  };
}

final class PipelineRunStop extends _PipelineRunAnswer {
  const PipelineRunStop(this.runId);

  static const String name = 'pipelineRuns.stop';

  final String runId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'runId': runId};
}

/// Runs the failed or stopped stage again, in a new session.
final class PipelineRunRetry extends _PipelineRunAnswer {
  const PipelineRunRetry(this.runId);

  static const String name = 'pipelineRuns.retry';

  final String runId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'runId': runId};
}

/// Passes over the current stage and goes on with the next.
final class PipelineRunSkip extends _PipelineRunAnswer {
  const PipelineRunSkip(this.runId);

  static const String name = 'pipelineRuns.skip';

  final String runId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'runId': runId};
}
