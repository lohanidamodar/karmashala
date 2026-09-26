import 'dart:convert';

import 'package:agent_cli/process.dart';

import 'comparison.dart';

// A comparison's wire shape — always with its candidates — and the rules a
// client's copy follows. Readers throw [FormatException] on a value out of
// shape.

String _time(DateTime at) => at.toUtc().toIso8601String();

DateTime _date(Object? value) => DateTime.parse(value! as String).toUtc();

T _named<T extends Enum>(List<T> values, Object? name, T orElse) =>
    values.firstWhere((v) => v.name == name, orElse: () => orElse);

Map<String, Object?> comparisonToJson(Comparison c) => {
  'id': c.id,
  'repositoryId': c.repositoryId,
  'prompt': c.prompt,
  'createdAt': _time(c.createdAt),
  'finishedAt': ?c.finishedAt == null ? null : _time(c.finishedAt!),
  'outcome': c.outcome.name,
  'winnerCandidateId': ?c.winnerCandidateId,
  'mergedCommit': ?c.mergedCommit,
  'archived': c.archived,
  'candidates': [
    for (final candidate in c.candidates) candidateToJson(candidate),
  ],
};

Comparison comparisonFromJson(Map<String, Object?> json) {
  try {
    return Comparison(
      id: json['id']! as String,
      repositoryId: json['repositoryId']! as String,
      prompt: json['prompt']! as String,
      createdAt: _date(json['createdAt']),
      finishedAt: json['finishedAt'] == null ? null : _date(json['finishedAt']),
      outcome: _named(
        ComparisonOutcome.values,
        json['outcome'],
        ComparisonOutcome.pending,
      ),
      winnerCandidateId: json['winnerCandidateId'] as String?,
      mergedCommit: json['mergedCommit'] as String?,
      archived: json['archived'] as bool? ?? false,
      candidates: [
        for (final c in json['candidates']! as List)
          candidateFromJson((c as Map).cast<String, Object?>()),
      ],
    );
  } on TypeError {
    throw const FormatException('not a comparison');
  }
}

Map<String, Object?> candidateToJson(ComparisonCandidate c) => {
  'id': c.id,
  'comparisonId': c.comparisonId,
  'position': c.position,
  'sessionId': ?c.sessionId,
  'installationId': c.installationId,
  'agentId': c.agentId,
  if (c.worktree case final worktree?)
    'worktree': {
      'environmentId': worktree.environmentId,
      'path': worktree.path,
    },
  'branch': ?c.branch,
  'launch': c.launch.name,
  'failure': ?c.failure,
  if (c.diff case final diff?) 'diff': diffStatToJson(diff),
  'worktreeRemoved': c.worktreeRemoved,
  if (c.evidence case final evidence?) 'evidence': evidenceToJson(evidence),
  'notes': ?c.notes,
};

ComparisonCandidate candidateFromJson(Map<String, Object?> json) {
  try {
    final worktree = json['worktree'] as Map?;
    final diff = json['diff'] as Map?;
    final evidence = json['evidence'] as Map?;
    return ComparisonCandidate(
      id: json['id']! as String,
      comparisonId: json['comparisonId']! as String,
      position: json['position']! as int,
      sessionId: json['sessionId'] as String?,
      installationId: json['installationId']! as String,
      agentId: json['agentId']! as String,
      worktree: worktree == null
          ? null
          : EnvironmentPath(
              environmentId: worktree['environmentId']! as String,
              path: worktree['path']! as String,
            ),
      branch: json['branch'] as String?,
      launch: _named(
        CandidateLaunchState.values,
        json['launch'],
        CandidateLaunchState.failed,
      ),
      failure: json['failure'] as String?,
      diff: diff == null
          ? null
          : diffStatFromJson(diff.cast<String, Object?>()),
      worktreeRemoved: json['worktreeRemoved'] as bool? ?? false,
      evidence: evidence == null
          ? null
          : evidenceFromJson(evidence.cast<String, Object?>()),
      notes: json['notes'] as String?,
    );
  } on TypeError {
    throw const FormatException('not a comparison candidate');
  }
}

Map<String, Object?> diffStatToJson(CandidateDiffStat stat) => {
  'filesChanged': stat.filesChanged,
  'insertions': stat.insertions,
  'deletions': stat.deletions,
  'commits': ?stat.commits,
  'capturedAt': _time(stat.capturedAt),
};

CandidateDiffStat diffStatFromJson(Map<String, Object?> json) {
  try {
    return CandidateDiffStat(
      filesChanged: json['filesChanged']! as int,
      insertions: json['insertions']! as int,
      deletions: json['deletions']! as int,
      commits: json['commits'] as int?,
      capturedAt: _date(json['capturedAt']),
    );
  } on TypeError {
    throw const FormatException('not a diff stat');
  }
}

Map<String, Object?> evidenceToJson(CandidateEvidence e) => {
  'verdict': e.verdict.name,
  'label': ?e.label,
  'runId': ?e.runId,
  'producerSessionId': ?e.producerSessionId,
};

CandidateEvidence evidenceFromJson(Map<String, Object?> json) =>
    CandidateEvidence(
      verdict: _named(
        EvidenceVerdict.values,
        json['verdict'],
        EvidenceVerdict.inconclusive,
      ),
      label: json['label'] as String?,
      runId: json['runId'] as String?,
      producerSessionId: json['producerSessionId'] as String?,
    );

/// Whether two comparisons say the same thing, candidates included.
bool sameComparison(Comparison a, Comparison b) =>
    jsonEncode(comparisonToJson(a)) == jsonEncode(comparisonToJson(b));

/// The store's order: newest first, then by id descending.
int compareComparisons(Comparison a, Comparison b) {
  final at = b.createdAt.compareTo(a.createdAt);
  return at != 0 ? at : b.id.compareTo(a.id);
}

/// Why [comparison] cannot be recorded, or null: a prompt, candidates of its
/// own in distinct positions.
String? comparisonProblem(Comparison comparison) {
  if (comparison.id.trim().isEmpty) return 'a comparison needs an id';
  if (comparison.prompt.trim().isEmpty) return 'a comparison needs a prompt';
  final positions = <int>{};
  final ids = <String>{};
  for (final c in comparison.candidates) {
    if (c.comparisonId != comparison.id) {
      return 'candidate ${c.id} belongs to another comparison';
    }
    if (!positions.add(c.position)) return 'two candidates share a position';
    if (!ids.add(c.id)) return 'two candidates share an id';
  }
  return null;
}
