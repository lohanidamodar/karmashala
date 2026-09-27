import 'package:agent_cli/process.dart';

import '../domain/worktree_contents.dart';
import 'worktree_cleanup_policy.dart';

/// What happened to one worktree in a sweep or a preview.
enum WorktreeCleanupOutcome {
  wouldRemove,
  removed,
  kept,
  failed;

  static WorktreeCleanupOutcome fromName(Object? name) => values.firstWhere(
    (outcome) => outcome.name == name,
    orElse: () => throw const FormatException('not a cleanup outcome'),
  );
}

/// One worktree's verdict: what was measured, what matched, what refused.
class WorktreeCleanupVerdict {
  const WorktreeCleanupVerdict({
    required this.facts,
    required this.outcome,
    this.matched = const [],
    this.refusals = const [],
    this.unmatched = const [],
    this.error,
    this.recheckedBeforeRemoval = false,
  });

  final WorktreeFacts facts;
  final WorktreeCleanupOutcome outcome;
  final List<WorktreeCleanupRule> matched;
  final List<WorktreeRefusal> refusals;

  /// Why each enabled rule did not match, when none did.
  final List<String> unmatched;

  /// Git's words, for [WorktreeCleanupOutcome.failed].
  final String? error;

  /// Kept because a refusal appeared between the scan and the removal.
  final bool recheckedBeforeRemoval;

  Map<String, Object?> toJson() => {
    'facts': worktreeFactsToJson(facts),
    'outcome': outcome.name,
    'matched': [for (final rule in matched) rule.name],
    'refusals': [
      for (final r in refusals) {'kind': r.kind.name, 'detail': r.detail},
    ],
    'unmatched': unmatched,
    'error': ?error,
    if (recheckedBeforeRemoval) 'recheckedBeforeRemoval': true,
  };

  static WorktreeCleanupVerdict fromJson(Map<String, Object?> json) =>
      WorktreeCleanupVerdict(
        facts: worktreeFactsFromJson(_map(json['facts'])),
        outcome: WorktreeCleanupOutcome.fromName(json['outcome']),
        matched: _rules(json['matched']),
        refusals: [
          for (final item in _list(json['refusals']))
            WorktreeRefusal(
              WorktreeRefusalKind.values.byName(_map(item)['kind']! as String),
              _map(item)['detail']! as String,
            ),
        ],
        unmatched: _strings(json['unmatched']),
        error: json['error'] as String?,
        recheckedBeforeRemoval: json['recheckedBeforeRemoval'] == true,
      );
}

/// A whole sweep or preview.
class WorktreeCleanupReport {
  const WorktreeCleanupReport({
    required this.at,
    required this.dryRun,
    required this.verdicts,
    this.notes = const [],
    this.notInspected = 0,
  });

  final DateTime at;
  final bool dryRun;
  final List<WorktreeCleanupVerdict> verdicts;

  /// Projects and checkouts that were skipped, and why.
  final List<String> notes;

  /// Worktrees past [kWorktreeCleanupMaxPerSweep], left for the next sweep.
  final int notInspected;

  Iterable<WorktreeCleanupVerdict> withOutcome(WorktreeCleanupOutcome o) =>
      verdicts.where((v) => v.outcome == o);

  Map<String, Object?> toJson() => {
    'at': at.toUtc().toIso8601String(),
    'dryRun': dryRun,
    'verdicts': [for (final v in verdicts) v.toJson()],
    'notes': notes,
    'notInspected': notInspected,
  };

  static WorktreeCleanupReport fromJson(Map<String, Object?> json) =>
      WorktreeCleanupReport(
        at: DateTime.parse(json['at']! as String),
        dryRun: json['dryRun'] == true,
        verdicts: [
          for (final item in _list(json['verdicts']))
            WorktreeCleanupVerdict.fromJson(_map(item)),
        ],
        notes: _strings(json['notes']),
        notInspected: json['notInspected'] is int
            ? json['notInspected']! as int
            : 0,
      );
}

/// One worktree an actual sweep removed, or tried to and git refused.
class WorktreeCleanupLogEntry {
  const WorktreeCleanupLogEntry({
    required this.at,
    required this.projectName,
    required this.worktreePath,
    required this.environmentId,
    required this.rules,
    required this.removed,
    this.branch,
    this.detail = '',
    this.automatic = true,
  });

  final DateTime at;
  final String projectName;
  final String worktreePath;
  final String environmentId;
  final String? branch;

  /// The rules that matched — the reason it went.
  final List<WorktreeCleanupRule> rules;

  /// False when the attempt failed; [detail] then carries git's words.
  final bool removed;
  final String detail;

  /// Whether the server's own schedule ran it, rather than a person pressing
  /// "Clean up now".
  final bool automatic;

  Map<String, Object?> toJson() => {
    'at': at.toUtc().toIso8601String(),
    'project': projectName,
    'path': worktreePath,
    'env': environmentId,
    'branch': ?branch,
    'rules': [for (final rule in rules) rule.name],
    'removed': removed,
    'detail': detail,
    'automatic': automatic,
  };

  static WorktreeCleanupLogEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final at = DateTime.tryParse('${json['at']}');
    final path = json['path'];
    if (at == null || path is! String) return null;
    return WorktreeCleanupLogEntry(
      at: at,
      projectName: '${json['project'] ?? ''}',
      worktreePath: path,
      environmentId: '${json['env'] ?? ''}',
      branch: json['branch'] as String?,
      rules: _rules(json['rules']),
      removed: json['removed'] == true,
      detail: '${json['detail'] ?? ''}',
      automatic: json['automatic'] != false,
    );
  }
}

/// The last sweep, for "last ran … removed 2, kept 5".
class WorktreeCleanupSweepSummary {
  const WorktreeCleanupSweepSummary({
    required this.startedAt,
    this.finishedAt,
    this.automatic = true,
    this.removed = 0,
    this.kept = 0,
    this.failed = 0,
    this.error,
  });

  final DateTime startedAt;
  final DateTime? finishedAt;
  final bool automatic;
  final int removed;
  final int kept;
  final int failed;
  final String? error;

  Map<String, Object?> toJson() => {
    'startedAt': startedAt.toUtc().toIso8601String(),
    if (finishedAt != null) 'finishedAt': finishedAt!.toUtc().toIso8601String(),
    'automatic': automatic,
    'removed': removed,
    'kept': kept,
    'failed': failed,
    'error': ?error,
  };

  static WorktreeCleanupSweepSummary? fromJson(Object? json) {
    if (json is! Map) return null;
    final started = DateTime.tryParse('${json['startedAt']}');
    if (started == null) return null;
    final finished = json['finishedAt'];
    int count(String key) => json[key] is int ? json[key] as int : 0;
    return WorktreeCleanupSweepSummary(
      startedAt: started,
      finishedAt: finished is String ? DateTime.tryParse(finished) : null,
      automatic: json['automatic'] != false,
      removed: count('removed'),
      kept: count('kept'),
      failed: count('failed'),
      error: json['error'] as String?,
    );
  }
}

/// What the server's cleanup has done: its removal log, newest first, and the
/// last sweep.
class WorktreeCleanupLog {
  const WorktreeCleanupLog({this.entries = const [], this.lastSweep});

  static const empty = WorktreeCleanupLog();

  final List<WorktreeCleanupLogEntry> entries;
  final WorktreeCleanupSweepSummary? lastSweep;

  Map<String, Object?> toJson() => {
    'entries': [for (final e in entries) e.toJson()],
    'lastSweep': lastSweep?.toJson(),
  };

  static WorktreeCleanupLog fromJson(Map<String, Object?> json) =>
      WorktreeCleanupLog(
        entries: [
          for (final item in _list(json['entries']))
            ?WorktreeCleanupLogEntry.fromJson(item),
        ],
        lastSweep: WorktreeCleanupSweepSummary.fromJson(json['lastSweep']),
      );
}

Map<String, Object?> worktreeFactsToJson(WorktreeFacts f) => {
  'projectId': f.projectId,
  'projectName': f.projectName,
  'repo': _pathToJson(f.repo),
  'path': _pathToJson(f.path),
  'branch': ?f.branch,
  'madeByKarmashala': f.madeByKarmashala,
  'liveSessions': f.liveSessions,
  'liveTerminal': f.liveTerminal,
  'sessionIds': f.sessionIds,
  if (f.contents case final c?)
    'contents': {'changes': c.changes, 'ignored': c.ignored},
  'contentsError': ?f.contentsError,
  'base': ?f.base,
  'commitsBeyondBase': ?f.commitsBeyondBase,
  'madeCommits': ?f.madeCommits,
  'lastActivity': ?f.lastActivity?.toUtc().toIso8601String(),
  'activitySource': ?f.activitySource,
};

WorktreeFacts worktreeFactsFromJson(Map<String, Object?> json) {
  final contents = json['contents'];
  final last = json['lastActivity'];
  return WorktreeFacts(
    projectId: json['projectId']! as String,
    projectName: json['projectName']! as String,
    repo: _pathFromJson(json['repo']),
    path: _pathFromJson(json['path']),
    branch: json['branch'] as String?,
    madeByKarmashala: json['madeByKarmashala'] != false,
    liveSessions: _strings(json['liveSessions']),
    liveTerminal: json['liveTerminal'] == true,
    sessionIds: _strings(json['sessionIds']),
    contents: contents is Map
        ? WorktreeContents(
            changes: _strings(contents['changes']),
            ignored: _strings(contents['ignored']),
          )
        : null,
    contentsError: json['contentsError'] as String?,
    base: json['base'] as String?,
    commitsBeyondBase: json['commitsBeyondBase'] as int?,
    madeCommits: json['madeCommits'] as bool?,
    lastActivity: last is String ? DateTime.parse(last) : null,
    activitySource: json['activitySource'] as String?,
  );
}

Map<String, Object?> _pathToJson(EnvironmentPath path) => {
  'environmentId': path.environmentId,
  'path': path.path,
};

EnvironmentPath _pathFromJson(Object? json) {
  final map = _map(json);
  return EnvironmentPath(
    environmentId: map['environmentId']! as String,
    path: map['path']! as String,
  );
}

Map<String, Object?> _map(Object? json) => json is Map
    ? json.cast<String, Object?>()
    : throw const FormatException('not an object');

List<Object?> _list(Object? json) => json is List ? json : const [];

List<String> _strings(Object? json) => [
  for (final item in _list(json))
    if (item is String) item,
];

List<WorktreeCleanupRule> _rules(Object? json) => [
  for (final name in _list(json))
    ?WorktreeCleanupRule.fromName(name as String?),
];
