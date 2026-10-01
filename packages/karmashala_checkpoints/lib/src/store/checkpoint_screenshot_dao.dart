import 'package:karmashala_store/database.dart';

import '../domain/checkpoint_screenshot.dart';

/// The `checkpoint_screenshots` table.
class CheckpointScreenshotDao {
  CheckpointScreenshotDao(this._db);

  final AppDatabase _db;

  void insert(CheckpointScreenshot shot) => _db.execute(
    'INSERT INTO checkpoint_screenshots (id, checkpoint_id, session_id, '
    'source, size, width, height, subject, label, path, captured_at) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
    [
      shot.id,
      shot.checkpointId,
      shot.sessionId,
      shot.source.name,
      shot.size,
      shot.width,
      shot.height,
      shot.subject,
      shot.label,
      shot.path,
      isoFromDate(shot.capturedAt),
    ],
  );

  CheckpointScreenshot? byId(String id) {
    final rows = _db.query(
      'SELECT * FROM checkpoint_screenshots WHERE id = ?;',
      [id],
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// [checkpointId]'s captures, oldest first.
  List<CheckpointScreenshot> forCheckpoint(String checkpointId) => [
    for (final row in _db.query(
      'SELECT * FROM checkpoint_screenshots WHERE checkpoint_id = ? '
      'ORDER BY captured_at, id;',
      [checkpointId],
    ))
      ?_fromRow(row),
  ];

  /// [sessionId]'s captures, newest first.
  List<CheckpointScreenshot> forSession(String sessionId, {int limit = 50}) => [
    for (final row in _db.query(
      'SELECT * FROM checkpoint_screenshots WHERE session_id = ? '
      'ORDER BY captured_at DESC, id DESC LIMIT ?;',
      [sessionId, limit],
    ))
      ?_fromRow(row),
  ];

  CheckpointScreenshot? _fromRow(Map<String, Object?> row) {
    final source = CheckpointScreenshotSource.parse(row['source'] as String?);
    if (source == null) return null;
    return CheckpointScreenshot(
      id: row['id']! as String,
      checkpointId: row['checkpoint_id']! as String,
      sessionId: row['session_id'] as String?,
      source: source,
      size: row['size']! as String,
      width: row['width']! as int,
      height: row['height']! as int,
      subject: row['subject'] as String?,
      label: row['label'] as String?,
      path: row['path']! as String,
      capturedAt: dateFromIso(row['captured_at']),
    );
  }
}
