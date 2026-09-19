/// Host-side push fan-out: attention-inbox news, sealed per device and handed
/// to the relay for the phones that cannot hear it live. Best-effort — a
/// failure is logged without content and dropped.
///
/// **This is where presence is spent, and the only place.** Presence only ever
/// SUPPRESSES a push for a phone that can already hear the news; nothing on the
/// delivery path may read it.
library;

import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../domain/companion_presence.dart';
import '../domain/paired_device.dart';
import '../protocol.dart';
import 'push_crypto.dart';
import 'relay_push_client.dart';

class PushFanout {
  PushFanout({
    required List<PairedDevice> Function() devices,
    required bool Function(String deviceId) hasLiveLink,
    required RelayPushClient? Function(PairedDevice device) clientFor,
    DateTime Function()? now,
    this.onLog,
  }) : _now = now ?? DateTime.now,
       // ignore: prefer_initializing_formals — private field, named for callers.
       _devices = devices,
       // ignore: prefer_initializing_formals — private field, named for callers.
       _hasLiveLink = hasLiveLink,
       // ignore: prefer_initializing_formals — private field, named for callers.
       _clientFor = clientFor;

  final List<PairedDevice> Function() _devices;
  final bool Function(String deviceId) _hasLiveLink;

  /// The push client for one device's OWN relay — null when that relay is off,
  /// which is exactly when a push through it could not arrive.
  final RelayPushClient? Function(PairedDevice device) _clientFor;
  final DateTime Function() _now;

  /// Lifecycle only — never called with a title, a token or a payload.
  final void Function(String message)? onLog;

  /// The token last registered with the relay, per device id, so a rotated
  /// token re-registers and an unchanged one does not repeat itself.
  final Map<String, String> _registeredTokens = {};

  /// Fans one piece of attention news out to every eligible device.
  /// Never throws.
  Future<void> notifyAttention({
    required String sessionId,
    required String title,
    required String kind,
    String? detail,
  }) async {
    for (final device in _devices()) {
      try {
        await _pushTo(
          device,
          sessionId: sessionId,
          title: title,
          kind: kind,
          detail: detail,
        );
      } on Object catch (error) {
        // Push is best-effort; the log names the failure, never the news.
        onLog?.call('push to a device failed: ${error.runtimeType}');
      }
    }
  }

  Future<void> _pushTo(
    PairedDevice device, {
    required String sessionId,
    required String title,
    required String kind,
    String? detail,
  }) async {
    if (device.revoked || device.deviceKey.isEmpty) return;
    if (!device.capabilities.has(Capability.receiveNotifications)) return;
    final token = device.pushToken;
    if (token == null || token.isEmpty) return;
    // A live link only says the phone can *hear* the news, and a backgrounded
    // app hears it into a window nobody can see. What is asked now is whether
    // the news is in front of its owner; every silence answers "assume it is".
    if (_hasLiveLink(device.id) &&
        presenceSuppressesPush(device.presence, sessionId)) {
      return;
    }
    // A device whose relay is switched off has nowhere for a push to land.
    final client = _clientFor(device);
    if (client == null) {
      onLog?.call('a push was not sent: that relay is off');
      return;
    }

    final key = SecretKeyData(device.deviceKey);
    final tag = await derivePushTag(key);
    final payloadB64 = base64Url.encode(
      await sealPushPayload(
        deviceKey: key,
        payload: attentionPushPayload(
          sessionId: sessionId,
          title: title,
          kind: kind,
          at: _now(),
          detail: detail,
        ),
      ),
    );
    final platform = device.pushPlatform ?? 'android';

    if (_registeredTokens[device.id] != token) {
      if (!await client.register(tag: tag, token: token, platform: platform)) {
        return;
      }
      _registeredTokens[device.id] = token;
    }
    var outcome = await client.push(tag: tag, payloadB64: payloadB64);
    if (outcome == PushOutcome.unknownTag) {
      // The relay restarted and forgot the tag: re-register, retry once.
      if (await client.register(tag: tag, token: token, platform: platform)) {
        outcome = await client.push(tag: tag, payloadB64: payloadB64);
      }
    }
    switch (outcome) {
      case PushOutcome.accepted:
        onLog?.call('a push left for the relay');
      case PushOutcome.tokenGone:
        // Registration must wait for the phone to bring a fresh token.
        _registeredTokens.remove(device.id);
        onLog?.call('a push token is gone; waiting for a fresh one');
      case PushOutcome.unknownTag:
      case PushOutcome.notConfigured:
      case PushOutcome.failed:
        onLog?.call('a push was not delivered: ${outcome.name}');
    }
  }
}
