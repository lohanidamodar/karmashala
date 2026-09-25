import 'package:agent_cli/descriptors.dart';

/// What the agent in one hosted session is doing, as the session host keeps
/// it: its status report, and — while that report is an open question — the
/// question itself, read off the hook that opened it. Keyed by the session
/// **row** id, which is what every client names a session by.
class HostedAgentStatus {
  const HostedAgentStatus({
    required this.sessionId,
    required this.report,
    this.question,
  });

  /// The session row's id (not the CLI's own conversation id, which the
  /// report carries).
  final String sessionId;

  final AgentStatusReport report;

  /// The open question, when [report] is one and the hook that opened it
  /// carried it. Null otherwise — a question seen only on the screen cannot
  /// be answered from outside the terminal.
  final AgentQuestionSet? question;

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'report': reportToJson(report),
    if (question case final question?) 'question': questionToJson(question),
  };

  /// Null for a shape this build cannot read — never a guessed status.
  static HostedAgentStatus? fromJson(Object? json) {
    if (json is! Map) return null;
    final sessionId = json['sessionId'];
    final report = reportFromJson(json['report']);
    if (sessionId is! String || report == null) return null;
    return HostedAgentStatus(
      sessionId: sessionId,
      report: report,
      question: questionFromJson(json['question']),
    );
  }

  @override
  String toString() => 'HostedAgentStatus($sessionId, $report)';
}

Map<String, Object?> reportToJson(AgentStatusReport report) => {
  'agentId': report.agentId,
  'sessionId': report.sessionId,
  'status': report.status.name,
  'source': report.source.name,
  'observedAt': report.observedAt.toUtc().toIso8601String(),
  if (report.sourceModifiedAt case final at?)
    'sourceModifiedAt': at.toUtc().toIso8601String(),
  'detail': ?report.detail,
  if (report.evidence.isNotEmpty) 'evidence': report.evidence,
  'waiting': report.waiting.name,
  if (report.ending case final ending?) 'ending': ending.name,
  'failureReason': ?report.failureReason,
};

AgentStatusReport? reportFromJson(Object? json) {
  if (json is! Map) return null;
  final agentId = json['agentId'];
  final sessionId = json['sessionId'];
  final status = _byName(AgentActivityStatus.values, json['status']);
  final source = _byName(AgentStatusSource.values, json['source']);
  final observedAt = _time(json['observedAt']);
  if (agentId is! String ||
      sessionId is! String ||
      status == null ||
      source == null ||
      observedAt == null) {
    return null;
  }
  final evidence = json['evidence'];
  return AgentStatusReport(
    agentId: agentId,
    sessionId: sessionId,
    status: status,
    source: source,
    observedAt: observedAt,
    sourceModifiedAt: _time(json['sourceModifiedAt']),
    detail: json['detail'] as String?,
    evidence: evidence is List ? evidence.whereType<String>().toList() : [],
    waiting:
        _byName(AgentWaitKind.values, json['waiting']) ??
        AgentWaitKind.unrecorded,
    ending: _byName(AgentSessionEnding.values, json['ending']),
    failureReason: json['failureReason'] as String?,
  );
}

Map<String, Object?> questionToJson(AgentQuestionSet set) => {
  'toolUseId': set.toolUseId,
  'questions': [
    for (final q in set.questions)
      {
        'question': q.question,
        'header': q.header,
        'multiSelect': q.multiSelect,
        'options': [
          for (final o in q.options)
            {'label': o.label, 'description': o.description},
        ],
      },
  ],
};

/// The tool input shape [AgentQuestionSet.fromToolInput] already reads, so a
/// question travels in the words the agent wrote it in.
AgentQuestionSet? questionFromJson(Object? json) {
  if (json is! Map) return null;
  final id = json['toolUseId'];
  if (id is! String) return null;
  return AgentQuestionSet.fromToolInput(id, json);
}

T? _byName<T extends Enum>(List<T> values, Object? name) {
  if (name is! String) return null;
  for (final value in values) {
    if (value.name == name) return value;
  }
  return null;
}

DateTime? _time(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;
