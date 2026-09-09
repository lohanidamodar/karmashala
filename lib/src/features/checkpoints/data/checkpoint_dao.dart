import 'package:riverpod/riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/database_providers.dart';
import '../../../core/database/row_mapping.dart';
import '../../environments/domain/environment_path.dart';
import '../../git/domain/file_change.dart';
import '../domain/checkpoint.dart';

/// Data access for session checkpoints (schema v12).
///
/// The rows are an index over git objects, not a copy of them: nothing here can
/// reconstruct a working tree on its own, and nothing here is authoritative
/// about content. Git is (ADR 0004).
class CheckpointDao {
  CheckpointDao(this._db);

  final AppDatabase _db;

  /// Inserts [checkpoint] with the next sequence number for its session, and
  /// returns it with that number filled in.
  Checkpoint insert(Checkpoint checkpoint) {
    return _db.transaction(() {
      final rows = _db.query(
        'SELECT COALESCE(MAX(sequence), 0) AS max_seq FROM session_checkpoints '
        'WHERE session_id = ?;',
        [checkpoint.sessionId],
      );
      final sequence = (rows.first['max_seq']! as int) + 1;

      _db.execute(
        'INSERT INTO session_checkpoints (id, session_id, environment_id, '
        'repository_path, sequence, tree_sha, commit_sha, parent_commit_sha, '
        'head_sha, reason, label, created_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
        [
          checkpoint.id,
          checkpoint.sessionId,
          checkpoint.repository.environmentId,
          checkpoint.repository.path,
          sequence,
          checkpoint.treeSha,
          checkpoint.commitSha,
          checkpoint.parentCommitSha,
          checkpoint.headSha,
          checkpoint.reason.name,
          checkpoint.label,
          isoFromDate(checkpoint.createdAt),
        ],
      );
      for (final file in checkpoint.files) {
        _db.execute(
          'INSERT OR REPLACE INTO session_checkpoint_files '
          '(checkpoint_id, path, status) VALUES (?, ?, ?);',
          [checkpoint.id, file.path, file.type.name],
        );
      }

      return Checkpoint(
        id: checkpoint.id,
        sessionId: checkpoint.sessionId,
        repository: checkpoint.repository,
        sequence: sequence,
        treeSha: checkpoint.treeSha,
        commitSha: checkpoint.commitSha,
        parentCommitSha: checkpoint.parentCommitSha,
        headSha: checkpoint.headSha,
        reason: checkpoint.reason,
        createdAt: checkpoint.createdAt,
        label: checkpoint.label,
        files: checkpoint.files,
      );
    });
  }

  /// Every checkpoint for [sessionId], oldest first.
  List<Checkpoint> forSession(String sessionId) => _read(
    'SELECT * FROM session_checkpoints WHERE session_id = ? '
    'ORDER BY sequence;',
    [sessionId],
  );

  /// The most recent checkpoint for [sessionId], or `null`.
  Checkpoint? latestFor(String sessionId) {
    final rows = _read(
      'SELECT * FROM session_checkpoints WHERE session_id = ? '
      'ORDER BY sequence DESC LIMIT 1;',
      [sessionId],
    );
    return rows.isEmpty ? null : rows.first;
  }

  Checkpoint? getById(String id) {
    final rows = _read('SELECT * FROM session_checkpoints WHERE id = ?;', [id]);
    return rows.isEmpty ? null : rows.first;
  }

  /// The most recent checkpoints across all sessions, newest first.
  List<Checkpoint> recent({int limit = 50}) => _read(
    'SELECT * FROM session_checkpoints ORDER BY created_at DESC LIMIT ?;',
    [limit],
  );

  /// Sessions that have at least one checkpoint, newest activity first.
  List<String> sessionsWithCheckpoints() {
    final rows = _db.query(
      'SELECT session_id, MAX(created_at) AS last FROM session_checkpoints '
      'GROUP BY session_id ORDER BY last DESC;',
    );
    return [for (final row in rows) row['session_id']! as String];
  }

  void deleteForSession(String sessionId) => _db.execute(
    'DELETE FROM session_checkpoints WHERE session_id = ?;',
    [sessionId],
  );

  List<Checkpoint> _read(String sql, List<Object?> params) {
    final rows = _db.query(sql, params);
    return [
      for (final row in rows)
        Checkpoint(
          id: row['id']! as String,
          sessionId: row['session_id']! as String,
          repository: EnvironmentPath(
            environmentId: row['environment_id']! as String,
            path: row['repository_path']! as String,
          ),
          sequence: row['sequence']! as int,
          treeSha: row['tree_sha']! as String,
          commitSha: row['commit_sha']! as String,
          parentCommitSha: row['parent_commit_sha'] as String?,
          headSha: row['head_sha'] as String?,
          reason: CheckpointReason.fromName(row['reason']! as String),
          label: row['label'] as String?,
          createdAt: dateFromIso(row['created_at']),
          files: _filesFor(row['id']! as String),
        ),
    ];
  }

  List<FileChange> _filesFor(String checkpointId) {
    final rows = _db.query(
      'SELECT path, status FROM session_checkpoint_files '
      'WHERE checkpoint_id = ? ORDER BY path;',
      [checkpointId],
    );
    return [
      for (final row in rows)
        FileChange(
          path: row['path']! as String,
          type: FileChangeType.values.firstWhere(
            (t) => t.name == row['status'],
            orElse: () => FileChangeType.unknown,
          ),
          staged: false,
          unstaged: true,
        ),
    ];
  }
}

final checkpointDaoProvider = Provider<CheckpointDao>(
  (ref) => CheckpointDao(ref.watch(databaseProvider)),
);
