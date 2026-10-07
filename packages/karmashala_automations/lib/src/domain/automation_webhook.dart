/// Calls a webhook accepts an hour unless its owner says otherwise.
const int kDefaultWebhookCallsPerHour = 30;

/// The most an owner may allow; above it the per-listen-id relay limit
/// (60 a minute) is what actually binds.
const int kMaxWebhookCallsPerHour = 600;

/// What makes an automation a webhook: it starts a new session when its URL
/// is called, with its prompt as the template. Its secret is not here — it
/// lives in the server's vault and is never part of a row or a snapshot.
class AutomationWebhook {
  const AutomationWebhook({
    this.hookId = '',
    this.requireSignature = true,
    this.callsPerHour = kDefaultWebhookCallsPerHour,
  });

  /// The URL's last segment: 128 random bits the server chose. Empty on a
  /// webhook a client has asked for and the server has not yet saved.
  final String hookId;

  /// Whether a call must carry a valid HMAC signature. Off, the URL alone is
  /// the credential.
  final bool requireSignature;

  /// Accepted calls allowed in any hour; a call beyond it is a 429.
  final int callsPerHour;

  AutomationWebhook copyWith({
    String? hookId,
    bool? requireSignature,
    int? callsPerHour,
  }) => AutomationWebhook(
    hookId: hookId ?? this.hookId,
    requireSignature: requireSignature ?? this.requireSignature,
    callsPerHour: callsPerHour ?? this.callsPerHour,
  );

  @override
  bool operator ==(Object other) =>
      other is AutomationWebhook &&
      other.hookId == hookId &&
      other.requireSignature == requireSignature &&
      other.callsPerHour == callsPerHour;

  @override
  int get hashCode => Object.hash(hookId, requireSignature, callsPerHour);

  @override
  String toString() => 'webhook';
}
