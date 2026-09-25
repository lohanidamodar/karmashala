import 'package:karmashala_store/database.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_git/git.dart';

import '../domain/checkpoint.dart';

/// Data access for session checkpoints. The rows are an index over git
/// objects, not a copy: git is authoritative about content (ADR 0004).
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
        'head_sha, reason, label, created_at, turn, prompt) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
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
          checkpoint.turn,
          checkpoint.prompt,
        ],
      );
      for (final file in checkpoint.files) {
        _db.execute(
          'INSERT OR REPLACE INTO session_checkpoint_files '
          '(checkpoint_id, path, status, additions, deletions) '
          'VALUES (?, ?, ?, ?, ?);',
          [
            checkpoint.id,
            file.path,
            file.type.name,
            checkpoint.lineStats[file.path]?.added,
            checkpoint.lineStats[file.path]?.removed,
          ],
        );
      }

      return _withSequence(checkpoint, sequence);
    });
  }

  /// Every checkpoint for [sessionId], oldest first.
  List<Checkpoint> forSession(String sessionId) => _read(
    'SELECT * FROM session_checkpoints WHERE session_id = ? '
    'ORDER BY sequence;',
    [sessionId],
  );

  /// [sessionId]'s checkpoints of one working tree, oldest first — the chain
  /// one ref holds. A session can checkpoint several repositories.
  List<Checkpoint> forRepository(
    String sessionId,
    EnvironmentPath repository,
  ) => _read(
    'SELECT * FROM session_checkpoints WHERE session_id = ? '
    'AND environment_id = ? AND repository_path = ? ORDER BY sequence;',
    [sessionId, repository.environmentId, repository.path],
  );

  /// The most recent checkpoint for [sessionId] — of [repository] when given,
  /// which is the only comparison a tree sha means anything in.
  Checkpoint? latestFor(String sessionId, {EnvironmentPath? repository}) {
    final rows = repository == null
        ? _read(
            'SELECT * FROM session_checkpoints WHERE session_id = ? '
            'ORDER BY sequence DESC LIMIT 1;',
            [sessionId],
          )
        : _read(
            'SELECT * FROM session_checkpoints WHERE session_id = ? '
            'AND environment_id = ? AND repository_path = ? '
            'ORDER BY sequence DESC LIMIT 1;',
            [sessionId, repository.environmentId, repository.path],
          );
    return rows.isEmpty ? null : rows.first;
  }

  /// The checkpoint of the same working tree taken just before [checkpoint].
  Checkpoint? previousOf(Checkpoint checkpoint) {
    final rows = _read(
      'SELECT * FROM session_checkpoints WHERE session_id = ? '
      'AND environment_id = ? AND repository_path = ? AND sequence < ? '
      'ORDER BY sequence DESC LIMIT 1;',
      [
        checkpoint.sessionId,
        checkpoint.repository.environmentId,
        checkpoint.repository.path,
        checkpoint.sequence,
      ],
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// The highest turn number recorded for [sessionId], or 0.
  int lastTurn(String sessionId) {
    final rows = _db.query(
      'SELECT COALESCE(MAX(turn), 0) AS turn FROM session_checkpoints '
      'WHERE session_id = ?;',
      [sessionId],
    );
    return rows.first['turn']! as int;
  }

  /// The working trees [sessionId] has checkpoints of, most recently used first.
  List<EnvironmentPath> repositoriesFor(String sessionId) {
    final rows = _db.query(
      'SELECT environment_id, repository_path, MAX(sequence) AS last '
      'FROM session_checkpoints WHERE session_id = ? '
      'GROUP BY environment_id, repository_path ORDER BY last DESC;',
      [sessionId],
    );
    return [
      for (final row in rows)
        EnvironmentPath(
          environmentId: row['environment_id']! as String,
          path: row['repository_path']! as String,
        ),
    ];
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

  /// Puts [label] on an existing checkpoint. Written after the fact because
  /// what it records — whether the tool this snapshot exists to undo had
  /// already been released when it was taken — is only known once the capture
  /// has returned.
  void relabel(String id, String label) => _db.execute(
    'UPDATE session_checkpoints SET label = ? WHERE id = ?;',
    [label, id],
  );

  void deleteForSession(String sessionId) => _db.execute(
    'DELETE FROM session_checkpoints WHERE session_id = ?;',
    [sessionId],
  );

  /// Drops [dropIds] and re-points the survivors at their rewritten commits, in
  /// one transaction so the rows never describe a chain git does not hold.
  void prune({
    required List<String> dropIds,
    required Map<String, ({String commit, String? parent})> rewritten,
  }) {
    _db.transaction(() {
      for (final id in dropIds) {
        _db.execute(
          'DELETE FROM session_checkpoint_files WHERE checkpoint_id = ?;',
          [id],
        );
        _db.execute('DELETE FROM session_checkpoints WHERE id = ?;', [id]);
      }
      for (final entry in rewritten.entries) {
        _db.execute(
          'UPDATE session_checkpoints SET commit_sha = ?, parent_commit_sha = ? '
          'WHERE id = ?;',
          [entry.value.commit, entry.value.parent, entry.key],
        );
      }
    });
  }

  Checkpoint _withSequence(Checkpoint c, int sequence) => Checkpoint(
    id: c.id,
    sessionId: c.sessionId,
    repository: c.repository,
    sequence: sequence,
    treeSha: c.treeSha,
    commitSha: c.commitSha,
    parentCommitSha: c.parentCommitSha,
    headSha: c.headSha,
    reason: c.reason,
    createdAt: c.createdAt,
    label: c.label,
    files: c.files,
    turn: c.turn,
    prompt: c.prompt,
    lineStats: c.lineStats,
  );

  List<Checkpoint> _read(String sql, List<Object?> params) {
    final rows = _db.query(sql, params);
    return [for (final row in rows) _fromRow(row)];
  }

  Checkpoint _fromRow(Map<String, Object?> row) {
    final id = row['id']! as String;
    final fileRows = _db.query(
      'SELECT path, status, additions, deletions FROM session_checkpoint_files '
      'WHERE checkpoint_id = ? ORDER BY path;',
      [id],
    );
    return Checkpoint(
      id: id,
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
      turn: row['turn'] as int?,
      prompt: row['prompt'] as String?,
      files: [
        for (final file in fileRows)
          FileChange(
            path: file['path']! as String,
            type: FileChangeType.values.firstWhere(
              (t) => t.name == file['status'],
              orElse: () => FileChangeType.unknown,
            ),
            staged: false,
            unstaged: true,
          ),
      ],
      lineStats: {
        for (final file in fileRows)
          if (file['additions'] != null || file['deletions'] != null)
            file['path']! as String: FileDiffStat(
              added: file['additions'] as int?,
              removed: file['deletions'] as int?,
            ),
      },
    );
  }
}
