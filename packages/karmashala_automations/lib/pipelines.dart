/// Pipelines: ordered stages of agent sessions with typed hand-offs, gates
/// and loop-backs, the templates they start from, and the runner that drives
/// them behind ports.
library;

export 'src/domain/pipeline.dart';
export 'src/domain/pipeline_run.dart';
export 'src/service/pipeline_ports.dart';
export 'src/service/pipeline_runner.dart';
