/// One session's hold on one physical device, and the refusal a second caller
/// gets while it stands.
///
/// ## Why a device gets a lock when a repository does not
///
/// `SETTLED.md` refuses leases for `terminal_run`, and that refusal is right
/// there for two reasons that both fail here. It rests on *"a lease an agent
/// cannot see is a hang"* — so this one is **visible**: every refusal names the
/// holder, says since when, and carries the age of both readings (§19). And it
/// rests on the leverage being capped, because an agent can always type into
/// its own pane. There is no such side door to a phone: `adb` is the only way
/// in and it is ours.
///
/// The thing being protected is different too. We run several agents against
/// one repository *by design* — a repository is a directory that can be
/// branched. A phone is a single physical surface, and two agents interleaving
/// taps on it produces garbage that reads as a flaky app rather than as a
/// collision.
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
  /// included.
  ///
  /// A drive is look-tap-look, so a read is as much evidence that the holder is
  /// still working as a tap is. Ageing only the taps would let a claim lapse in
  /// the middle of a careful drive, which is the one moment it exists for.
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

/// The device is somebody else's right now.
///
/// Its own type rather than a `DeviceRefusal` so a caller — and a test — can
/// tell "another agent is driving this" apart from "this device cannot do
/// that". They call for opposite responses: one is worth waiting out, the other
/// never will be.
class DeviceBusy implements Exception {
  const DeviceBusy(this.message, {required this.claim});

  final String message;
  final DeviceClaim claim;

  @override
  String toString() => message;
}

/// How long a claim survives with no device call from its holder.
///
/// Two minutes because a drive is a tight loop — dump, tap, dump — whose gaps
/// are seconds, and because the cost of getting this wrong is symmetric and
/// visible in both directions: too short and the displaced holder's next call
/// is refused *by name* and it can simply take the device back; too long and a
/// second agent waits. Silence is not.
const Duration kDeviceClaimLapse = Duration(minutes: 2);

/// An age in the seconds-to-minutes range, which is the range a drive lives in.
///
/// `describeAge` is deliberately coarse — everything under a minute is "just
/// now" — because it exists to say how much to trust a stored reading. Here the
/// question is whether the holder is still tapping, and rendering a claim taken
/// forty seconds ago and one taken two seconds ago with the same three words is
/// exactly the reading that hides the answer.
String describeDriveAge(Duration age) {
  if (age.isNegative || age.inSeconds < 1) return 'just now';
  if (age.inSeconds < 60) return '${age.inSeconds}s ago';
  if (age.inMinutes < 60) return '${age.inMinutes}m ago';
  return '${age.inHours}h ago';
}
