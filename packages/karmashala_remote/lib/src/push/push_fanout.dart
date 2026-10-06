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

/// How long a relay that answered 503 — push not configured there, or full —
/// is left alone before it is asked again. Pushes meanwhile go to the next
/// relay that can carry them, or nowhere, but never back at it on each one.
const Duration kPushUnavailableRetry = Duration(minutes: 30);

class PushFanout {
  PushFanout({
    required List<PairedDevice> Function() devices,
    required bool Function(String deviceId) hasLiveLink,
    required RelayPushClient? Function(PairedDevice device) clientFor,
    List<RelayPushClient> Function(PairedDevice device)? fallbackClientsFor,
    DateTime Function()? now,
    this.onLog,
  }) : _now = now ?? DateTime.now,
       // ignore: prefer_initializing_formals — private field, named for callers.
       _devices = devices,
       // ignore: prefer_initializing_formals — private field, named for callers.
       _hasLiveLink = hasLiveLink,
       // ignore: prefer_initializing_formals — private field, named for callers.
       _clientFor = clientFor,
       // ignore: prefer_initializing_formals — private field, named for callers.
       _fallbackClientsFor = fallbackClientsFor;

  final List<PairedDevice> Function() _devices;
  final bool Function(String deviceId) _hasLiveLink;

  /// The push client for one device's OWN relay — null when that relay is off,
  /// which is exactly when a push through it could not arrive.
  final RelayPushClient? Function(PairedDevice device) _clientFor;

  /// Relays tried, in order, while the device's own cannot carry a push — the
  /// one it moved off, which may still deliver.
  final List<RelayPushClient> Function(PairedDevice device)?
  _fallbackClientsFor;
  final DateTime Function() _now;

  /// Lifecycle only — never called with a title, a token or a payload.
  final void Function(String message)? onLog;

  /// The token last registered, per device and relay, so a rotated token
  /// re-registers, an unchanged one does not repeat itself, and a relay the
  /// device moved to is registered with afresh.
  final Map<String, String> _registeredTokens = {};

  /// Relays that answered 503, until they are asked again.
  final Map<String, DateTime> _unavailableUntil = {};

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
    final own = _clientFor(device);
    if (own == null) {
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

    final seen = <String>{};
    for (final client in [own, ...?_fallbackClientsFor?.call(device)]) {
      final relay = client.pushEndpoint.toString();
      if (!seen.add(relay)) continue;
      final until = _unavailableUntil[relay];
      if (until != null && _now().isBefore(until)) continue;
      final outcome = await _deliver(
        client,
        device: device,
        tag: tag,
        token: token,
        platform: platform,
        payloadB64: payloadB64,
      );
      switch (outcome) {
        case PushOutcome.accepted:
          _unavailableUntil.remove(relay);
          onLog?.call('a push left for the relay');
          return;
        case PushOutcome.notConfigured:
          _unavailableUntil[relay] = _now().add(kPushUnavailableRetry);
          onLog?.call(
            'push unavailable at ${client.pushEndpoint.host}; asked again in '
            '${kPushUnavailableRetry.inMinutes} min',
          );
          continue;
        case PushOutcome.tokenGone:
          // Registration must wait for the phone to bring a fresh token.
          _registeredTokens.removeWhere(
            (k, _) => k.startsWith('${device.id}|'),
          );
          onLog?.call('a push token is gone; waiting for a fresh one');
          return;
        case PushOutcome.unknownTag:
        case PushOutcome.failed:
          onLog?.call('a push was not delivered: ${outcome.name}');
          return;
      }
    }
    onLog?.call('a push was not sent: no relay can carry it now');
  }

  /// Registers [token] on [client]'s relay when it has not been, then pushes;
  /// a relay that forgot the tag is registered with again, once.
  Future<PushOutcome> _deliver(
    RelayPushClient client, {
    required PairedDevice device,
    required String tag,
    required String token,
    required String platform,
    required String payloadB64,
  }) async {
    final registered = '${device.id}|${client.registerEndpoint}';
    Future<PushOutcome> register() async {
      final outcome = await client.registerOutcome(
        tag: tag,
        token: token,
        platform: platform,
      );
      if (outcome == PushOutcome.accepted) {
        _registeredTokens[registered] = token;
      }
      return outcome;
    }

    if (_registeredTokens[registered] != token) {
      final outcome = await register();
      if (outcome != PushOutcome.accepted) return outcome;
    }
    var outcome = await client.push(tag: tag, payloadB64: payloadB64);
    if (outcome == PushOutcome.unknownTag) {
      // The relay restarted and forgot the tag: re-register, retry once.
      final again = await register();
      if (again != PushOutcome.accepted) return again;
      outcome = await client.push(tag: tag, payloadB64: payloadB64);
    }
    return outcome;
  }
}
