/// One session's hold on one physical device, and the refusal a second caller
/// gets while it stands.
///
/// `SETTLED.md` refuses leases for `terminal_run` because a lease an agent
/// cannot see is a hang — this one names its holder, and its age, in every
/// refusal. And a phone has no side door: `adb` is the only way in, where an
/// agent can always type into its own pane.
library;

/// A session's standing hold on one device.
class DeviceClaim {
  const DeviceClaim({
    required this.deviceId,
    required this.holderSessionId,
    required this.holderTitle,
    required this.takenAt,
    required this.lastCallAt,
    required this.lastVerb,
    required this.calls,
  });

  /// The device as its driver names it — `emulator-5554`, or a simulator udid.
  final String deviceId;

  final String holderSessionId;

  /// What to call the holder. Null when the app has the id and nothing else,
  /// which is a weaker sentence rather than a licence to invent a name.
  final String? holderTitle;

  final DateTime takenAt;

  /// When the holder last called *any* device tool on this device, reads
  /// included. A drive is look-tap-look, so ageing only the taps would lapse a
  /// claim in the middle of a careful one.
  final DateTime lastCallAt;

  final String lastVerb;

  /// Device calls in this run. Counted rather than timed: it is what says
  /// whether the holder got started or is one call in.
  final int calls;

  DeviceClaim onCall(String verb, DateTime at) => DeviceClaim(
    deviceId: deviceId,
    holderSessionId: holderSessionId,
    holderTitle: holderTitle,
    takenAt: takenAt,
    lastCallAt: at,
    lastVerb: verb,
    calls: calls + 1,
  );

  DeviceClaim renamedTo(String? title) => DeviceClaim(
    deviceId: deviceId,
    holderSessionId: holderSessionId,
    holderTitle: title,
    takenAt: takenAt,
    lastCallAt: lastCallAt,
    lastVerb: lastVerb,
    calls: calls,
  );

  /// The holder, as a refusal names it: the title when we have one, and the
  /// session id always — the id is the handle the reader can act on.
  String get holderLabel => holderTitle == null
      ? 'session $holderSessionId'
      : '"$holderTitle" (session $holderSessionId)';
}

/// The device is somebody else's right now. Its own type so a caller can tell
/// "another agent is driving this" from "this device cannot do that": one is
/// worth waiting out and the other never will be.
class DeviceBusy implements Exception {
  const DeviceBusy(this.message, {required this.claim});

  final String message;
  final DeviceClaim claim;

  @override
  String toString() => message;
}

/// How long a claim survives with no device call from its holder. Two minutes:
/// a drive's gaps are seconds, and a displaced holder's next call is refused *by
/// name*, so it can simply take the device back.
const Duration kDeviceClaimLapse = Duration(minutes: 2);

/// An age in the seconds-to-minutes range, which is the range a drive lives in.
/// `describeAge` is too coarse here — forty seconds and two seconds both read as
/// "just now", which is exactly the reading that hides the answer.
String describeDriveAge(Duration age) {
  if (age.isNegative || age.inSeconds < 1) return 'just now';
  if (age.inSeconds < 60) return '${age.inSeconds}s ago';
  if (age.inMinutes < 60) return '${age.inMinutes}m ago';
  return '${age.inHours}h ago';
}
