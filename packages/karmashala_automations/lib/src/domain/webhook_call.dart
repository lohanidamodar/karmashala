/// Calls kept per hook; older ones are pruned as new ones arrive.
const int kWebhookCallsKept = 200;

/// One call to a webhook URL, accepted or refused. Never the body: its hash
/// and its size are what a person checks a delivery against.
class WebhookCall {
  const WebhookCall({
    required this.id,
    required this.automationId,
    required this.hookId,
    required this.receivedAt,
    required this.ip,
    required this.status,
    required this.outcome,
    required this.bodyHash,
    required this.bodyBytes,
    this.reason,
    this.deliveryId,
    this.sessionId,
    this.runId,
  });

  final String id;

  /// Null for a call to a hook id no webhook has.
  final String? automationId;
  final String hookId;
  final DateTime receivedAt;

  /// The caller's address as the relay reported it; empty when it did not.
  final String ip;

  /// The status the caller was answered with.
  final int status;

  /// A word or two: `accepted`, `bad signature`, `replay`…
  final String outcome;

  /// Why, in the owner's words — what the caller is never told.
  final String? reason;
  final String? deliveryId;

  /// SHA-256 of the raw body, hex.
  final String bodyHash;
  final int bodyBytes;
  final String? sessionId;
  final String? runId;

  bool get accepted => status == 202;
}

Map<String, Object?> webhookCallToJson(WebhookCall c) => {
  'id': c.id,
  'automationId': c.automationId,
  'hookId': c.hookId,
  'receivedAt': c.receivedAt.toUtc().toIso8601String(),
  'ip': c.ip,
  'status': c.status,
  'outcome': c.outcome,
  'reason': c.reason,
  'deliveryId': c.deliveryId,
  'bodyHash': c.bodyHash,
  'bodyBytes': c.bodyBytes,
  'sessionId': c.sessionId,
  'runId': c.runId,
};

WebhookCall webhookCallFromJson(Map<String, Object?> json) => WebhookCall(
  id: json['id']! as String,
  automationId: json['automationId'] as String?,
  hookId: json['hookId']! as String,
  receivedAt: DateTime.parse(json['receivedAt']! as String).toUtc(),
  ip: json['ip'] as String? ?? '',
  status: json['status']! as int,
  outcome: json['outcome'] as String? ?? '',
  reason: json['reason'] as String?,
  deliveryId: json['deliveryId'] as String?,
  bodyHash: json['bodyHash'] as String? ?? '',
  bodyBytes: json['bodyBytes'] as int? ?? 0,
  sessionId: json['sessionId'] as String?,
  runId: json['runId'] as String?,
);
