import 'package:karmashala_store/database.dart';

import '../domain/webhook_call.dart';

/// The webhook call log. Hand-written SQL; no body is ever stored.
class WebhookCallDao {
  WebhookCallDao(this._db);

  final AppDatabase _db;

  void insert(WebhookCall call) => _db.execute(
    'INSERT INTO webhook_calls (id, automation_id, hook_id, received_at, ip, '
    'status, outcome, reason, delivery_id, body_sha256, body_bytes, '
    'session_id, run_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
    [
      call.id,
      call.automationId,
      call.hookId,
      isoFromDate(call.receivedAt),
      call.ip,
      call.status,
      call.outcome,
      call.reason,
      call.deliveryId,
      call.bodyHash,
      call.bodyBytes,
      call.sessionId,
      call.runId,
    ],
  );

  /// [automationId]'s calls, newest first.
  List<WebhookCall> forAutomation(String automationId, {int limit = 50}) => _db
      .query(
        'SELECT * FROM webhook_calls WHERE automation_id = ? '
        'ORDER BY received_at DESC, id DESC LIMIT ?;',
        [automationId, limit],
      )
      .map(_call)
      .toList();

  /// Calls [automationId] accepted at or after [since].
  int acceptedSince(String automationId, DateTime since) =>
      _db.query(
            'SELECT COUNT(*) AS n FROM webhook_calls WHERE automation_id = ? '
            'AND status = 202 AND received_at >= ?;',
            [automationId, isoFromDate(since)],
          ).first['n']!
          as int;

  /// Whether [deliveryId] was accepted for [hookId] at or after [since]. A
  /// refused delivery does not count, so a sender's honest retry goes through.
  bool deliverySeen(
    String hookId,
    String deliveryId, {
    required DateTime since,
  }) => _db.query(
    'SELECT 1 FROM webhook_calls WHERE hook_id = ? AND delivery_id = ? '
    'AND status = 202 AND received_at >= ? LIMIT 1;',
    [hookId, deliveryId, isoFromDate(since)],
  ).isNotEmpty;

  /// Keeps the newest [kWebhookCallsKept] calls for [hookId].
  void prune(String hookId) => _db.execute(
    'DELETE FROM webhook_calls WHERE hook_id = ? AND id NOT IN ('
    'SELECT id FROM webhook_calls WHERE hook_id = ? '
    'ORDER BY received_at DESC, id DESC LIMIT ?);',
    [hookId, hookId, kWebhookCallsKept],
  );

  WebhookCall _call(Map<String, Object?> row) => WebhookCall(
    id: row['id']! as String,
    automationId: row['automation_id'] as String?,
    hookId: row['hook_id']! as String,
    receivedAt: dateFromIso(row['received_at']),
    ip: row['ip'] as String? ?? '',
    status: row['status']! as int,
    outcome: row['outcome']! as String,
    reason: row['reason'] as String?,
    deliveryId: row['delivery_id'] as String?,
    bodyHash: row['body_sha256']! as String,
    bodyBytes: row['body_bytes'] as int? ?? 0,
    sessionId: row['session_id'] as String?,
    runId: row['run_id'] as String?,
  );
}
