/// What an agent is doing right now, as far as any status source can tell.
///
/// [unknown] is a first-class state, not an error: most agents sit there until
/// hooks are installed or a state file can be classified. Nothing in the status
/// pipeline throws to express "we don't know".
enum AgentActivityStatus { idle, working, awaitingApproval, failed, unknown }

/// Which source produced a status report.
enum AgentStatusSource {
  /// A callback from a hook installed into the agent's own config.
  hook,

  /// The agent's session/state file on disk.
  stateFile,

  /// Nothing could tell us anything.
  none,
}

/// One observation of an agent session's status.
class AgentStatusReport {
  const AgentStatusReport({
    required this.agentId,
    required this.sessionId,
    required this.status,
    required this.source,
    required this.observedAt,
    this.detail,
  });

  /// Registry id of the agent (`AgentDescriptor.id`).
  final String agentId;

  /// The CLI's own session id — the key both sources share.
  final String sessionId;

  final AgentActivityStatus status;
  final AgentStatusSource source;
  final DateTime observedAt;

  /// Why the source concluded this (hook event name, matched record value, …).
  final String? detail;

  @override
  String toString() =>
      'AgentStatusReport($agentId/$sessionId, ${status.name}, ${source.name})';
}

/// What to ask the status service about.
class AgentStatusQuery {
  const AgentStatusQuery({
    required this.agentId,
    required this.sessionId,
    this.stateFilePath,
  });

  final String agentId;
  final String sessionId;

  /// The session transcript's path, as already known from CLI detection or an
  /// imported session. `null` when we have no file to read.
  final String? stateFilePath;
}

/// Matches one decoded state-file record by walking [path] into it and
/// comparing the value's string form to [equals].
class StateRecordMatcher {
  const StateRecordMatcher(this.path, this.equals);

  final List<String> path;
  final String equals;

  bool matches(Map<String, Object?> record) {
    Object? value = record;
    for (final segment in path) {
      if (value is! Map) return false;
      value = value[segment];
    }
    return value is String && value == equals;
  }

  @override
  String toString() => '${path.join('.')}=$equals';
}

/// How to classify an agent's state file. All matcher lists are evaluated
/// against the file's **last** decodable record.
class AgentStateFileRules {
  const AgentStateFileRules({
    this.idle = const [],
    this.working = const [],
    this.awaitingApproval = const [],
    this.failed = const [],
    this.activityWindow = const Duration(minutes: 2),
  });

  final List<StateRecordMatcher> idle;
  final List<StateRecordMatcher> working;
  final List<StateRecordMatcher> awaitingApproval;
  final List<StateRecordMatcher> failed;

  /// How recently the file must have changed for a `working` record to still
  /// mean "working" rather than "the CLI exited mid-turn".
  final Duration activityWindow;
}

/// How to install callbacks into an agent's own hook configuration, and what
/// each callback means.
class AgentHookSpec {
  const AgentHookSpec({
    required this.configFileName,
    this.configKey = 'hooks',
    this.sessionIdPath = const ['session_id'],
    required this.eventStatus,
  });

  /// Config file inside the agent's store home, e.g. `settings.json`.
  final String configFileName;

  /// Top-level key in that file holding the hook map.
  final String configKey;

  /// Where the agent's session id sits in the hook payload.
  final List<String> sessionIdPath;

  /// Hook event name → the status it implies.
  final Map<String, AgentActivityStatus> eventStatus;
}
