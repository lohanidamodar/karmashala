/// Where a pipeline run's inbox items point: opening one opens the run in
/// Workflows → Runs.
const String kPipelineInboxPrefix = 'pipelines:';

/// The inbox's address for pipeline run [runId].
String pipelineInboxOpenId(String runId) => '$kPipelineInboxPrefix$runId';

/// The pipeline run an inbox address names, or null for anything else's.
String? pipelineRunIdOfInboxId(String openId) =>
    openId.startsWith(kPipelineInboxPrefix)
    ? openId.substring(kPipelineInboxPrefix.length)
    : null;
