import 'package:agent_cli/process.dart';
import 'package:karmashala_verification/verification.dart';

/// What happened to a comparison in the end.
enum ComparisonOutcome {
  /// Nobody has won yet.
  pending,

  /// A winner's branch was merged; [Comparison.mergedCommit] says into what.
  merged,

  /// Closed without merging anything.
  discarded,
}

/// Whether a candidate's agent ever started.
enum CandidateLaunchState { started, failed }

/// A verification verdict, as far as this comparison is concerned.
enum EvidenceVerdict { passed, failed, inconclusive }

/// What a candidate's worktree showed the last time anyone looked. Recorded
/// rather than recomputed: the directory goes, the number does not.
class CandidateDiffStat {
  const CandidateDiffStat({
    required this.filesChanged,
    required this.insertions,
    required this.deletions,
    required this.capturedAt,
    this.commits,
  });

  /// Files touched in the working tree (uncommitted).
  final int filesChanged;
  final int insertions;
  final int deletions;

  /// Commits the candidate's branch has that the repository's branch does not,
  /// or `null` when git could not tell. Never collapse `null` into zero.
  final int? commits;

  final DateTime capturedAt;

  bool get isEmpty => filesChanged == 0 && (commits ?? 0) == 0;

  /// One line for a card: `3 files +42 -7 · 2 commits`. Lines show even with no
  /// file counted — a committed clean tree has files 0 and commits 2.
  String get summary {
    final changed = <String>[
      if (filesChanged > 0) '$filesChanged file${filesChanged == 1 ? '' : 's'}',
      if (insertions > 0 || deletions > 0) '+$insertions −$deletions',
    ].join(' ');
    final parts = <String>[
      if (changed.isNotEmpty) changed,
      if ((commits ?? 0) > 0) '$commits commit${commits == 1 ? '' : 's'}',
    ];
    return parts.isEmpty ? 'no changes' : parts.join(' · ');
  }

  CandidateDiffStat copyWith({int? commits}) => CandidateDiffStat(
    filesChanged: filesChanged,
    insertions: insertions,
    deletions: deletions,
    capturedAt: capturedAt,
    commits: commits ?? this.commits,
  );

  @override
  bool operator ==(Object other) =>
      other is CandidateDiffStat &&
      other.filesChanged == filesChanged &&
      other.insertions == insertions &&
      other.deletions == deletions &&
      other.commits == commits &&
      other.capturedAt == capturedAt;

  @override
  int get hashCode =>
      Object.hash(filesChanged, insertions, deletions, commits, capturedAt);

  @override
  String toString() => 'CandidateDiffStat($summary)';
}

/// A verification result attached to a candidate: the verdict and a label,
/// never the run, so an old comparison keeps it after the run is pruned.
class CandidateEvidence {
  const CandidateEvidence({
    required this.verdict,
    this.label,
    this.runId,
    this.producerSessionId,
  });

  final EvidenceVerdict verdict;

  /// What the verdict was about — "8 tests, 1 failed", "no console errors".
  final String? label;

  /// The verification run this came from, when one is known.
  final String? runId;

  /// The session that produced the verdict, or null when nobody recorded one.
  /// Copied with the verdict: one that outlives its attribution is the failure.
  final String? producerSessionId;

  /// Whether the candidate's own session produced this verdict. Takes the
  /// subject rather than storing it — the candidate already holds it.
  VerdictAttribution attributionFor(String? subjectSessionId) =>
      VerdictAttribution.of(
        producerSessionId: producerSessionId,
        subjectSessionId: subjectSessionId,
      );

  @override
  bool operator ==(Object other) =>
      other is CandidateEvidence &&
      other.verdict == verdict &&
      other.label == label &&
      other.runId == runId &&
      other.producerSessionId == producerSessionId;

  @override
  int get hashCode => Object.hash(verdict, label, runId, producerSessionId);

  @override
  String toString() => 'CandidateEvidence(${verdict.name}, $label)';
}

/// One agent's attempt at the shared prompt, as a durable record. [sessionId]
/// is no foreign key and [worktree] outlives the directory it names.
class ComparisonCandidate {
  const ComparisonCandidate({
    required this.id,
    required this.comparisonId,
    required this.position,
    required this.installationId,
    required this.agentId,
    required this.launch,
    this.sessionId,
    this.worktree,
    this.branch,
    this.failure,
    this.diff,
    this.worktreeRemoved = false,
    this.evidence,
    this.notes,
  });

  final String id;
  final String comparisonId;

  /// Where it sits in the row of candidates — the order the user asked for.
  final int position;

  /// The session that ran it, or `null` when it never started.
  final String? sessionId;

  final String installationId;

  /// Copied, not looked up: an installation can be removed and the record must
  /// still say which agent this was.
  final String agentId;

  final EnvironmentPath? worktree;
  final String? branch;

  final CandidateLaunchState launch;

  /// Why it did not start, for [CandidateLaunchState.failed].
  final String? failure;

  final CandidateDiffStat? diff;

  /// Whether the worktree directory has been removed. The record stays.
  final bool worktreeRemoved;

  final CandidateEvidence? evidence;
  final String? notes;

  bool get started => launch == CandidateLaunchState.started;

  /// Who graded this candidate: itself, another session, or nobody recorded.
  VerdictAttribution get evidenceAttribution =>
      evidence?.attributionFor(sessionId) ?? VerdictAttribution.notRecorded;

  /// Whether there is still a directory to diff, merge or open.
  bool get hasLiveWorktree => worktree != null && !worktreeRemoved;

  ComparisonCandidate copyWith({
    String? sessionId,
    EnvironmentPath? worktree,
    String? branch,
    CandidateLaunchState? launch,
    String? failure,
    CandidateDiffStat? diff,
    bool? worktreeRemoved,
    CandidateEvidence? evidence,
    String? notes,
  }) => ComparisonCandidate(
    id: id,
    comparisonId: comparisonId,
    position: position,
    installationId: installationId,
    agentId: agentId,
    launch: launch ?? this.launch,
    sessionId: sessionId ?? this.sessionId,
    worktree: worktree ?? this.worktree,
    branch: branch ?? this.branch,
    failure: failure ?? this.failure,
    diff: diff ?? this.diff,
    worktreeRemoved: worktreeRemoved ?? this.worktreeRemoved,
    evidence: evidence ?? this.evidence,
    notes: notes ?? this.notes,
  );

  @override
  String toString() =>
      'ComparisonCandidate($id, $agentId, ${launch.name}, ${diff?.summary})';
}

/// One prompt, several agents, and what came of it.
class Comparison {
  const Comparison({
    required this.id,
    required this.repositoryId,
    required this.prompt,
    required this.createdAt,
    required this.candidates,
    this.finishedAt,
    this.outcome = ComparisonOutcome.pending,
    this.winnerCandidateId,
    this.mergedCommit,
    this.archived = false,
  });

  final String id;
  final String repositoryId;
  final String prompt;
  final DateTime createdAt;

  /// When a winner was merged or the comparison was closed out.
  final DateTime? finishedAt;

  final ComparisonOutcome outcome;
  final String? winnerCandidateId;

  /// The commit the merge landed on, when [outcome] is
  /// [ComparisonOutcome.merged].
  final String? mergedCommit;

  final bool archived;

  /// Candidates in request order.
  final List<ComparisonCandidate> candidates;

  ComparisonCandidate? get winner {
    final id = winnerCandidateId;
    if (id == null) return null;
    for (final candidate in candidates) {
      if (candidate.id == id) return candidate;
    }
    return null;
  }

  int get startedCount => candidates.where((c) => c.started).length;

  /// The merge commit, abbreviated the way git abbreviates it.
  String? get shortMergedCommit {
    final sha = mergedCommit;
    if (sha == null) return null;
    return sha.length >= 7 ? sha.substring(0, 7) : sha;
  }

  /// The prompt's first line, trimmed for a list row.
  String get title {
    final line = prompt.trim().split('\n').first.trim();
    return line.length <= 90 ? line : '${line.substring(0, 89)}…';
  }

  Comparison copyWith({
    DateTime? finishedAt,
    ComparisonOutcome? outcome,
    String? winnerCandidateId,
    String? mergedCommit,
    bool? archived,
    List<ComparisonCandidate>? candidates,
  }) => Comparison(
    id: id,
    repositoryId: repositoryId,
    prompt: prompt,
    createdAt: createdAt,
    candidates: candidates ?? this.candidates,
    finishedAt: finishedAt ?? this.finishedAt,
    outcome: outcome ?? this.outcome,
    winnerCandidateId: winnerCandidateId ?? this.winnerCandidateId,
    mergedCommit: mergedCommit ?? this.mergedCommit,
    archived: archived ?? this.archived,
  );

  @override
  String toString() =>
      'Comparison($id, ${candidates.length} candidates, ${outcome.name})';
}
