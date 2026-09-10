/// The companion's receive path for an opaque push: unseal with the paired
/// device key, map through the attention-notification wording, render. Ignorant
/// of how the bytes arrived; one that will not open shows nothing.
library;

import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'package:karmashala_remote/client.dart' as stored;
import 'package:karmashala_remote/push.dart';
import 'package:karmashala_remote/companion.dart';
import '../notifications/attention_notification.dart';

class CompanionPushReceiver {
  CompanionPushReceiver({
    required this.store,
    required this.show,
    DateTime Function()? now,
    this.onLog,
  }) : _now = now ?? DateTime.now;

  /// Where the pairing record lives — `SecureCompanionStore` on a phone.
  final stored.CompanionStore store;

  /// Renders one notification; a recorder in tests.
  final Future<void> Function(AttentionNotification notification) show;

  final DateTime Function() _now;

  /// Lifecycle only — never called with decrypted content.
  final void Function(String message)? onLog;

  /// The shape an FCM message handler holds: `message.data`, whose `payload`
  /// key is unsealed.
  Future<void> handleData(Map<Object?, Object?> data) async {
    final payload = data['payload'];
    if (payload is! String || payload.isEmpty) {
      onLog?.call('push message carried no payload');
      return;
    }
    await handleOpaquePayload(payload);
  }

  /// Unseals one base64url push payload and shows its notification.
  Future<void> handleOpaquePayload(String payloadB64) async {
    try {
      final record = await stored.CompanionPairing.load(store);
      if (record == null) {
        onLog?.call('push for an unpaired phone dropped');
        return;
      }
      final sealed = base64Url.decode(base64Url.normalize(payloadB64.trim()));
      final payload = await openPushPayload(
        deviceKey: SecretKeyData(record.deviceKey),
        sealed: sealed,
      );
      final sessionId = payload['sessionId'];
      if (sessionId is! String || sessionId.isEmpty) {
        onLog?.call('push payload named no session');
        return;
      }
      final title = payload['title'];
      final at = payload['at'];
      final event = CompanionAttentionEvent(
        sessionId: sessionId,
        sessionTitle: title is String && title.isNotEmpty ? title : sessionId,
        kind: _kindOf(payload['kind']),
        at:
            (at is String ? DateTime.tryParse(at)?.toUtc() : null) ??
            _now().toUtc(),
      );
      await show(notificationFor(event));
    } on Object catch (error) {
      // Opening someone else's — or corrupted — bytes fails quietly.
      onLog?.call('push payload refused: ${error.runtimeType}');
    }
  }

  /// The gateway's wire-word mapping: an unknown claim on the user reads as
  /// "needs you".
  CompanionAttentionKind _kindOf(Object? kind) => switch (kind) {
    'finished' => CompanionAttentionKind.finished,
    'failed' => CompanionAttentionKind.failed,
    _ => CompanionAttentionKind.needsYou,
  };
}
