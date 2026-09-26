import 'dart:convert';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show PreferenceStore;

import '../application/worktree_cleanup_policy.dart';

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

  /// Whether the timer ran it, rather than a person pressing "Clean up now".
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
    final rules = json['rules'];
    return WorktreeCleanupLogEntry(
      at: at,
      projectName: '${json['project'] ?? ''}',
      worktreePath: path,
      environmentId: '${json['env'] ?? ''}',
      branch: json['branch'] as String?,
      rules: rules is List
          ? [
              for (final name in rules)
                ?WorktreeCleanupRule.fromName(name as String?),
            ]
          : const [],
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

/// Worktree cleanup's setting, removal log and last sweep, all among this
/// app's preferences at the server.
class WorktreeCleanupStore {
  WorktreeCleanupStore(this._db);

  final PreferenceStore _db;

  static const String settingsKey = 'worktree_cleanup.settings.v1';
  static const String logKey = 'worktree_cleanup.log.v1';
  static const String lastSweepKey = 'worktree_cleanup.last_sweep.v1';

  /// Entries kept in the log; the oldest fall off.
  static const int logLimit = 200;

  Object? _read(String key) {
    final raw = _db.read(key);
    if (raw == null) return null;
    try {
      return jsonDecode(raw);
    } on FormatException {
      return null;
    }
  }

  WorktreeCleanupSettings settings() =>
      WorktreeCleanupSettings.fromJson(_read(settingsKey));

  void saveSettings(WorktreeCleanupSettings settings) =>
      _db.write(settingsKey, jsonEncode(settings.toJson()));

  /// Newest first.
  List<WorktreeCleanupLogEntry> log() {
    final decoded = _read(logKey);
    if (decoded is! List) return const [];
    return [
      for (final entry in decoded) ?WorktreeCleanupLogEntry.fromJson(entry),
    ];
  }

  void appendLog(WorktreeCleanupLogEntry entry) {
    final next = [entry, ...log()].take(logLimit);
    _db.write(logKey, jsonEncode([for (final e in next) e.toJson()]));
  }

  WorktreeCleanupSweepSummary? lastSweep() =>
      WorktreeCleanupSweepSummary.fromJson(_read(lastSweepKey));

  void saveLastSweep(WorktreeCleanupSweepSummary summary) =>
      _db.write(lastSweepKey, jsonEncode(summary.toJson()));
}
