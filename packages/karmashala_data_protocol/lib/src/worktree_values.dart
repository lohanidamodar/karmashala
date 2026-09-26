import 'package:karmashala_git/git.dart';
import 'package:karmashala_snippets/karmashala_snippets.dart';

// The wire shape of the git side tables, snippets and presets.

Map<String, Object?> worktreeSetupToJson(WorktreeSetup setup) => {
  'command': setup.command,
  'copyPaths': setup.copyPaths,
  'startAgentBeforeSetup': setup.startAgentBeforeSetup,
  'teardown': setup.teardown,
};

WorktreeSetup worktreeSetupFromJson(Map<String, Object?> json) {
  final start = json['startAgentBeforeSetup'];
  if (start is! bool) throw const FormatException('not a worktree setup');
  return WorktreeSetup(
    command: _strings(json['command']),
    copyPaths: _strings(json['copyPaths']),
    startAgentBeforeSetup: start,
    teardown: _strings(json['teardown']),
  );
}

Map<String, Object?> setupReportToJson(WorktreeSetupReport report) => {
  'repositoryId': report.repositoryId,
  'worktreePath': report.worktreePath,
  'environmentId': report.environmentId,
  'ranAt': report.ranAt.toUtc().toIso8601String(),
  'detail': report.toJsonString(),
};

WorktreeSetupReport setupReportFromJson(Map<String, Object?> json) {
  final repositoryId = json['repositoryId'], path = json['worktreePath'];
  final environmentId = json['environmentId'], detail = json['detail'];
  final ranAt = DateTime.tryParse('${json['ranAt']}');
  if (repositoryId is! String ||
      path is! String ||
      environmentId is! String ||
      detail is! String ||
      ranAt == null) {
    throw const FormatException('not a worktree setup run');
  }
  return WorktreeSetupReport.fromStored(
    repositoryId: repositoryId,
    worktreePath: path,
    environmentId: environmentId,
    ranAt: ranAt.toUtc(),
    detail: detail,
  );
}

/// Two reports say the same — a report has no `==` of its own.
bool sameSetupReport(WorktreeSetupReport a, WorktreeSetupReport b) =>
    a.key == b.key &&
    a.environmentId == b.environmentId &&
    a.ranAt == b.ranAt &&
    a.toJsonString() == b.toJsonString();

Map<String, Object?> reviewAnchorToJson(ReviewAnchor anchor) => {
  'path': anchor.path,
  'blobSha': anchor.blobSha,
  'startLine': anchor.startLine,
  'endLine': anchor.endLine,
  'excerpt': anchor.excerpt,
};

ReviewAnchor reviewAnchorFromJson(Map<String, Object?> json) {
  final path = json['path'], sha = json['blobSha'];
  if (path is! String || sha is! String) {
    throw const FormatException('not a review anchor');
  }
  return ReviewAnchor(
    path: path,
    blobSha: sha,
    startLine: json['startLine'] as int?,
    endLine: json['endLine'] as int?,
    excerpt: json['excerpt'] as String?,
  );
}

Map<String, Object?> reviewThreadToJson(ReviewThread thread) => {
  'id': thread.id,
  'repositoryId': thread.repositoryId,
  'anchor': reviewAnchorToJson(thread.anchor),
  'status': thread.status.name,
  'sessionId': thread.sessionId,
  'createdAt': thread.createdAt.toUtc().toIso8601String(),
  'updatedAt': thread.updatedAt.toUtc().toIso8601String(),
  'comments': [
    for (final c in thread.comments)
      {
        'id': c.id,
        'sequence': c.sequence,
        'author': c.author,
        'authorKind': c.authorKind.name,
        'body': c.body,
        'createdAt': c.createdAt.toUtc().toIso8601String(),
      },
  ],
};

ReviewThread reviewThreadFromJson(Map<String, Object?> json) {
  final id = json['id'], repositoryId = json['repositoryId'];
  final anchor = json['anchor'], comments = json['comments'];
  final created = DateTime.tryParse('${json['createdAt']}');
  final updated = DateTime.tryParse('${json['updatedAt']}');
  if (id is! String ||
      repositoryId is! String ||
      anchor is! Map ||
      comments is! List ||
      created == null ||
      updated == null) {
    throw const FormatException('not a review thread');
  }
  return ReviewThread(
    id: id,
    repositoryId: repositoryId,
    anchor: reviewAnchorFromJson(anchor.cast<String, Object?>()),
    status: ReviewThreadStatus.fromName(json['status'] as String?),
    sessionId: json['sessionId'] as String?,
    createdAt: created.toUtc(),
    updatedAt: updated.toUtc(),
    comments: [
      for (final raw in comments)
        if (raw is Map)
          ReviewComment(
            id: raw['id'] as int?,
            threadId: id,
            sequence: raw['sequence'] as int? ?? 0,
            author: raw['author'] as String? ?? '',
            authorKind: ReviewAuthorKind.fromName(raw['authorKind'] as String?),
            body: raw['body'] as String? ?? '',
            createdAt:
                DateTime.tryParse('${raw['createdAt']}')?.toUtc() ??
                created.toUtc(),
          )
        else
          throw const FormatException('not a review comment'),
    ],
  );
}

/// Two threads say the same — a thread has no `==` of its own.
bool sameReviewThread(ReviewThread a, ReviewThread b) =>
    a.id == b.id &&
    a.updatedAt == b.updatedAt &&
    a.status == b.status &&
    a.comments.length == b.comments.length;

/// The git side tables whole: each checkout's worktree setup, the verdict of
/// every worktree's setup run, and every review thread with its comments.
final class WorktreesSnapshot {
  const WorktreesSnapshot({
    this.setups = const {},
    this.runs = const [],
    this.threads = const [],
  });

  final Map<String, WorktreeSetup> setups;
  final List<WorktreeSetupReport> runs;
  final List<ReviewThread> threads;

  Map<String, Object?> toJson() => {
    'setups': {
      for (final entry in setups.entries)
        entry.key: worktreeSetupToJson(entry.value),
    },
    'runs': [for (final r in runs) setupReportToJson(r)],
    'threads': [for (final t in threads) reviewThreadToJson(t)],
  };

  static WorktreesSnapshot fromJson(Map<String, Object?> json) {
    final setups = json['setups'];
    if (setups is! Map) throw const FormatException('expected setups');
    return WorktreesSnapshot(
      setups: {
        for (final entry in setups.entries)
          entry.key as String: worktreeSetupFromJson(
            (entry.value as Map).cast<String, Object?>(),
          ),
      },
      runs: _list(json['runs'], setupReportFromJson),
      threads: _list(json['threads'], reviewThreadFromJson),
    );
  }
}

/// The command snippets and saved terminal presets whole.
final class SnippetsSnapshot {
  const SnippetsSnapshot({this.snippets = const [], this.presets = const []});

  final List<CommandSnippet> snippets;
  final List<StoredPreset> presets;

  Map<String, Object?> toJson() => {
    'snippets': [for (final s in snippets) s.toJson()],
    'presets': [for (final p in presets) p.toJson()],
  };

  static SnippetsSnapshot fromJson(Map<String, Object?> json) =>
      SnippetsSnapshot(
        snippets: _list(json['snippets'], CommandSnippet.fromJson),
        presets: _list(json['presets'], StoredPreset.fromJson),
      );
}

List<String> _strings(Object? json) => json is List
    ? [
        for (final item in json)
          if (item is String) item else throw const FormatException('argv'),
      ]
    : throw const FormatException('expected a list of strings');

List<T> _list<T>(Object? json, T Function(Map<String, Object?>) read) =>
    json is List
    ? [
        for (final item in json)
          item is Map
              ? read(item.cast<String, Object?>())
              : throw const FormatException('expected an object'),
      ]
    : throw const FormatException('expected a list');
