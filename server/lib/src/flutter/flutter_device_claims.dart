/// Who is driving a device, as the server's Flutter runs see it. The app's
/// `device_*` tools keep their own claims on the desktop; this port is what
/// the server asks before a `flutter run` takes a device.
abstract interface class FlutterDeviceClaims {
  /// Takes or renews [sessionId]'s claim on [deviceId]; the refusal in words
  /// when another session holds it, else null.
  String? claim({
    required String deviceId,
    required String? sessionId,
    required String verb,
  });
}

/// The server's own claims: one holder per device, lapsing after [lapsesAfter]
/// with no call from it.
class MemoryFlutterDeviceClaims implements FlutterDeviceClaims {
  MemoryFlutterDeviceClaims({
    DateTime Function()? clock,
    this.lapsesAfter = const Duration(minutes: 10),
  }) : _now = clock ?? DateTime.now;

  final DateTime Function() _now;
  final Duration lapsesAfter;
  final _held = <String, ({String sessionId, DateTime at})>{};

  @override
  String? claim({
    required String deviceId,
    required String? sessionId,
    required String verb,
  }) {
    final now = _now();
    final held = _held[deviceId];
    if (held != null && now.difference(held.at) >= lapsesAfter) {
      _held.remove(deviceId);
    } else if (held != null && held.sessionId != sessionId) {
      return '$verb: $deviceId is being driven by session ${held.sessionId}. '
          'The claim lapses on its own after ${lapsesAfter.inMinutes}m with no '
          'call from that session.';
    }
    if (sessionId != null) _held[deviceId] = (sessionId: sessionId, at: now);
    return null;
  }
}
