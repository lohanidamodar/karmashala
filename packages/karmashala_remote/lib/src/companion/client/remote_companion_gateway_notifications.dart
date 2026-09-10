part of 'remote_companion_gateway.dart';

// Presence, and the `notifications.register` it rides on.
//
// **Presence is not delivery.** Nothing here decides whether a row reaches a
// stream: the host routes a *push* by it, in `push_fanout.dart`, where presence
// SUPPRESSES a push for a phone that can already hear the news.

extension _GatewayNotifications on RemoteCompanionGateway {
  /// One frame per change, and **never a tick**: an unchanged presence sends
  /// nothing at all, so the frame count on the wire follows what actually
  /// happened on the phone.
  Future<void> _report(CompanionPresence next) async {
    final proposed = next.copyWith(deviceKind: deviceKind);
    if (proposed.saysSameAs(_presence)) return;
    _presence = proposed;
    final client = _client;
    // Nothing is queued for a link that is down: the next connection registers
    // anyway, and it carries whatever the latest answer is by then.
    if (client == null || !client.isConnected) return;
    await _registerPushToken(client);
  }

  /// `notifications.register`, once per connection and again on every change
  /// of presence — only with the capability granted and a token source wired
  /// (Loop D's FCM). No source, a null token, or a refusal all skip silently:
  /// registration is plumbing.
  Future<void> _registerPushToken(CompanionClient client) async {
    final source = pushTokenSource;
    final record = _record;
    if (source == null || record == null) return;
    if (!record.capabilities.has(Capability.receiveNotifications)) return;
    try {
      final token = await source();
      if (token == null || _client != client || !client.isConnected) return;
      await client.registerNotifications(
        token: token.token,
        platform: token.platform,
        presence: _presence,
      );
    } on Object catch (error) {
      onLog?.call('notifications.register failed: $error');
    }
  }
}
