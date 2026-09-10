import 'package:karmashala_core/util.dart';
import 'package:riverpod/riverpod.dart';

import '../../devices.dart';
import 'device_ports.dart';

/// What to call the session [sessionId], or **null when it is over**. One
/// lookup for two questions: a holder we can name is one that still exists.
typedef DeviceClaimHolderLookup = String? Function(String sessionId);

/// One task per device: which session drives each one, and what a second
/// caller is told. Nothing polls — a claim ends only when somebody asks.
class DeviceClaims {
  DeviceClaims({
    required this.clock,
    required this.holder,
    this.lapsesAfter = kDeviceClaimLapse,
  });

  final Clock clock;

  /// See [DeviceClaimHolderLookup]: what a session is called, or null when it
  /// is over.
  final DeviceClaimHolderLookup holder;

  final Duration lapsesAfter;

  final Map<String, DeviceClaim> _byDevice = <String, DeviceClaim>{};

  /// The claim on [deviceId] that is still standing, or null. Prunes as it
  /// reads, which is the whole of the expiry mechanism.
  DeviceClaim? standing(String deviceId) {
    final held = _byDevice[deviceId];
    if (held == null) return null;
    final title = holder(held.holderSessionId);
    if (title == null) {
      _byDevice.remove(deviceId);
      return null;
    }
    if (clock.nowUtc().difference(held.lastCallAt) >= lapsesAfter) {
      _byDevice.remove(deviceId);
      return null;
    }
    // Re-read every time rather than cached: a session renamed mid-drive must
    // be refused under the name the reader would recognise.
    final current = held.renamedTo(title);
    _byDevice[deviceId] = current;
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
      throw DeviceBusy(_busyMessage(verb, held, now), claim: held);
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
  void release(String sessionId) => _byDevice.removeWhere(
    (_, claim) => claim.holderSessionId == sessionId,
  );

  /// Every claim still standing, newest hold last. For a caller that wants to
  /// show them; nothing in the refusal path needs it.
  List<DeviceClaim> get standingClaims => [
    for (final deviceId in _byDevice.keys.toList()) ?standing(deviceId),
  ];

  void clear() => _byDevice.clear();

  /// The refusal: names the holder, and says what clears it without anybody
  /// doing anything — a block whose end cannot be predicted is a hang.
  String _busyMessage(String verb, DeviceClaim held, DateTime now) =>
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
}

/// The one claim registry. Its default names no holder, so nothing is ever
/// busy; the app overrides it with a lookup through its session store, which
/// reads a DAO and is why that half cannot live here.
final deviceClaimsProvider = Provider<DeviceClaims>(
  (ref) => DeviceClaims(
    clock: ref.watch(deviceClockProvider),
    holder: (_) => null,
  ),
);
