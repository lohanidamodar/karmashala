import 'package:karmashala_core/util.dart';

import '../../devices.dart';

/// What to call the session [sessionId], or **null when it is over**. One
/// lookup for two questions: a holder we can name is one that still exists.
typedef DeviceClaimHolderLookup = String? Function(String sessionId);

/// One task per device: which session drives each one, and what a second
/// caller is told. The server's alone (slice 4a): its agent tools, its Flutter
/// runs and a person's actions in a pane on the server's machine all ask this
/// one registry. Nothing here polls — a claim ends when its session does, or
/// lapses when read; [sweep] is how an owner looks for both.
class DeviceClaims {
  DeviceClaims({
    required this.clock,
    required this.holder,
    this.lapsesAfter = kDeviceClaimLapse,
    this.onChanged,
  });

  final Clock clock;

  /// See [DeviceClaimHolderLookup]: what a session is called, or null when it
  /// is over.
  final DeviceClaimHolderLookup holder;

  final Duration lapsesAfter;

  /// Told after a claim is taken, released, lapses or its holder is renamed —
  /// never for a renewal, which changes who holds nothing.
  void Function()? onChanged;

  final Map<String, DeviceClaim> _byDevice = <String, DeviceClaim>{};

  void _changed() => onChanged?.call();

  /// The claim on [deviceId] that is still standing, or null. Prunes as it
  /// reads, which is the whole of the expiry mechanism.
  DeviceClaim? standing(String deviceId) {
    final held = _byDevice[deviceId];
    if (held == null) return null;
    final title = holder(held.holderSessionId);
    if (title == null ||
        clock.nowUtc().difference(held.lastCallAt) >= lapsesAfter) {
      _byDevice.remove(deviceId);
      _changed();
      return null;
    }
    // Re-read every time rather than cached: a session renamed mid-drive must
    // be refused under the name the reader would recognise.
    final current = held.renamedTo(title);
    _byDevice[deviceId] = current;
    if (current.holderTitle != held.holderTitle) _changed();
    return current;
  }

  /// Takes or renews [sessionId]'s claim on [deviceId], or throws [DeviceBusy]
  /// naming the holder. [deviceId] is canonical, so two spellings collide.
  DeviceClaim? claim({
    required String deviceId,
    required String? sessionId,
    required String verb,
  }) {
    final held = standing(deviceId);
    final now = clock.nowUtc();
    if (held != null && held.holderSessionId != sessionId) {
      throw DeviceBusy(
        deviceBusyMessage(verb, held, now, lapsesAfter: lapsesAfter),
        claim: held,
      );
    }
    if (sessionId == null) return null;
    final taken =
        held?.onCall(verb, now) ??
        DeviceClaim(
          deviceId: deviceId,
          holderSessionId: sessionId,
          holderTitle: holder(sessionId),
          takenAt: now,
          lastCallAt: now,
          lastVerb: verb,
          calls: 1,
        );
    _byDevice[deviceId] = taken;
    if (held == null) _changed();
    return taken;
  }

  /// Records that [sessionId] looked at [deviceId]: renews a claim it already
  /// holds and **never makes one** — reading a screen changes nothing.
  void observed({required String deviceId, required String? sessionId}) {
    if (sessionId == null) return;
    final held = standing(deviceId);
    if (held == null || held.holderSessionId != sessionId) return;
    _byDevice[deviceId] = held.onCall(held.lastVerb, clock.nowUtc());
  }

  /// Drops everything [sessionId] holds, because that session is over.
  void release(String sessionId) {
    final before = _byDevice.length;
    _byDevice.removeWhere((_, claim) => claim.holderSessionId == sessionId);
    if (_byDevice.length != before) _changed();
  }

  /// Reads every claim, which drops the ones whose session is over or which
  /// have lapsed — telling [onChanged] if any went.
  void sweep() => standingClaims;

  /// Every claim held, as last read — without reading again, so an
  /// [onChanged] listener can say what stands without pruning under itself.
  List<DeviceClaim> get held => List.unmodifiable(_byDevice.values);

  /// Every claim still standing, newest hold last. For a caller that wants to
  /// show them; nothing in the refusal path needs it.
  List<DeviceClaim> get standingClaims => [
    for (final deviceId in _byDevice.keys.toList()) ?standing(deviceId),
  ];

  void clear() {
    if (_byDevice.isEmpty) return;
    _byDevice.clear();
    _changed();
  }
}

/// The refusal: names the holder, and says what clears it without anybody
/// doing anything — a block whose end cannot be predicted is a hang. One
/// wording for the server's refusal and a pane's question.
String deviceBusyMessage(
  String verb,
  DeviceClaim held,
  DateTime now, {
  Duration lapsesAfter = kDeviceClaimLapse,
}) =>
    '$verb: ${held.deviceId} is being driven by another agent. '
    'Held by ${held.holderLabel} since '
    '${describeDriveAge(now.difference(held.takenAt))}, '
    '${held.calls} device call${held.calls == 1 ? '' : 's'} in, last '
    '${held.lastVerb} ${describeDriveAge(now.difference(held.lastCallAt))}. '
    'Nothing here takes a device off a working holder. It is released when '
    'that session ends, and the claim lapses on its own after '
    '${lapsesAfter.inMinutes}m with no device call from it, so this clears '
    'without anybody doing anything if it has stopped. Reading is never '
    'blocked: device_screenshot, device_ui_dump, device_find_elements and '
    'device_logcat all work while somebody else is driving.';
