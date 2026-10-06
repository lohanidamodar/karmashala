import 'package:agent_cli/process.dart';
import 'package:karmashala_store/database.dart';

import '../domain/artifact.dart';

/// The `session_artifacts` and `session_artifact_revisions` tables.
class ArtifactDao {
  ArtifactDao(this._db);

  final AppDatabase _db;

  void insert(Artifact a) => _db.execute(
    'INSERT INTO session_artifacts (id, session_id, title, kind, mode, origin, '
    'source_environment_id, source_path, file_name, revision, size, '
    'mime_type, network_allowed, source_state, source_problem, created_at, '
    'updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
    [
      a.id,
      a.sessionId,
      a.title,
      a.kind.name,
      a.mode.name,
      a.origin.name,
      a.source?.environmentId,
      a.source?.path,
      a.fileName,
      a.revision,
      a.size,
      a.mimeType,
      a.networkAllowed ? 1 : 0,
      a.sourceState.name,
      a.sourceProblem,
      isoFromDate(a.createdAt),
      isoFromDate(a.updatedAt),
    ],
  );

  /// Writes what may change after an artifact is made.
  void update(Artifact a) => _db.execute(
    'UPDATE session_artifacts SET title = ?, mode = ?, revision = ?, '
    'size = ?, network_allowed = ?, source_state = ?, source_problem = ?, '
    'updated_at = ? WHERE id = ?;',
    [
      a.title,
      a.mode.name,
      a.revision,
      a.size,
      a.networkAllowed ? 1 : 0,
      a.sourceState.name,
      a.sourceProblem,
      isoFromDate(a.updatedAt),
      a.id,
    ],
  );

  Artifact? byId(String id) {
    final rows = _db.query('SELECT * FROM session_artifacts WHERE id = ?;', [
      id,
    ]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// [sessionId]'s artifacts, oldest first — the order they were shown in.
  List<Artifact> forSession(String sessionId) => [
    for (final row in _db.query(
      'SELECT * FROM session_artifacts WHERE session_id = ? '
      'ORDER BY created_at, id;',
      [sessionId],
    ))
      ?_fromRow(row),
  ];

  Artifact? bySource(String sessionId, EnvironmentPath source) {
    final rows = _db.query(
      'SELECT * FROM session_artifacts WHERE session_id = ? AND '
      'source_environment_id = ? AND source_path = ? LIMIT 1;',
      [sessionId, source.environmentId, source.path],
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// The newest [limit] artifacts read from a host file, newest first.
  List<Artifact> withSource({int limit = 200}) => [
    for (final row in _db.query(
      'SELECT * FROM session_artifacts WHERE source_path IS NOT NULL '
      'ORDER BY updated_at DESC LIMIT ?;',
      [limit],
    ))
      ?_fromRow(row),
  ];

  void insertRevision(ArtifactRevision r) => _db.execute(
    'INSERT INTO session_artifact_revisions (artifact_id, revision, size, '
    'digest, path, captured_at) VALUES (?, ?, ?, ?, ?, ?);',
    [
      r.artifactId,
      r.revision,
      r.size,
      r.digest,
      r.path,
      isoFromDate(r.capturedAt),
    ],
  );

  /// [artifactId]'s kept revisions, oldest first.
  List<ArtifactRevision> revisions(String artifactId) => [
    for (final row in _db.query(
      'SELECT * FROM session_artifact_revisions WHERE artifact_id = ? '
      'ORDER BY revision;',
      [artifactId],
    ))
      ArtifactRevision(
        artifactId: row['artifact_id']! as String,
        revision: row['revision']! as int,
        size: row['size']! as int,
        digest: row['digest']! as String,
        path: row['path']! as String,
        capturedAt: dateFromIso(row['captured_at']),
      ),
  ];

  void deleteRevision(String artifactId, int revision) => _db.execute(
    'DELETE FROM session_artifact_revisions WHERE artifact_id = ? AND '
    'revision = ?;',
    [artifactId, revision],
  );

  Artifact? _fromRow(Map<String, Object?> row) {
    final kind = ArtifactKind.parse(row['kind'] as String?);
    final mode = ArtifactMode.parse(row['mode'] as String?);
    final origin = ArtifactOrigin.parse(row['origin'] as String?);
    if (kind == null || mode == null || origin == null) return null;
    final environmentId = row['source_environment_id'] as String?;
    final path = row['source_path'] as String?;
    return Artifact(
      id: row['id']! as String,
      sessionId: row['session_id']! as String,
      title: row['title']! as String,
      kind: kind,
      mode: mode,
      origin: origin,
      source: environmentId == null || path == null
          ? null
          : EnvironmentPath(environmentId: environmentId, path: path),
      fileName: row['file_name']! as String,
      revision: row['revision']! as int,
      size: row['size']! as int,
      mimeType: row['mime_type']! as String,
      networkAllowed: row['network_allowed'] == 1,
      sourceState:
          ArtifactSourceState.parse(row['source_state'] as String?) ??
          ArtifactSourceState.present,
      sourceProblem: row['source_problem'] as String?,
      createdAt: dateFromIso(row['created_at']),
      updatedAt: dateFromIso(row['updated_at']),
    );
  }
}
