import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock.dart';
import '../../../core/util/clock_provider.dart';
import '../../sessions/application/session_providers.dart';
import '../domain/device_claim.dart';

/// What to call the session [sessionId], or **null when it is over**.
///
/// One lookup for two questions on purpose. A holder we can still name is a
/// holder that still exists, and asking "is it alive" separately from "what is
/// it called" is how the two answers get out of step.
typedef DeviceClaimHolderLookup = String? Function(String sessionId);

/// One task per device: which session is driving each one, and what a second
/// caller is told while it is.
///
/// ## Nothing polls, and nothing expires on a timer
///
/// There is no sweep, no `Timer`, no periodic reconciliation. Both ways a claim
/// ends are evaluated **only when somebody asks for the device**, which is the
/// same rule §19 states for health readings and for the same reason: a claim
/// nobody is contending for costs nothing to be wrong about.
///
/// ## What happens when the holder dies without releasing
///
/// This is the part a device lock gets wrong, and getting it wrong is worse
/// than having no lock at all: a claim that outlives its owner makes the phone
/// permanently unusable and reads as a hardware fault. Three answers, in the
/// order they are checked:
///
/// 1. **The session is over** — archived, completed, failed, cancelled, or its
///    row is gone. [DeviceClaimHolderLookup] answers null and the claim is
///    void. This is the honest case: there is nobody left to be the holder.
/// 2. **The holder went quiet** for [kDeviceClaimLapse]. The claim lapses on
///    its own. This is what covers the case the app cannot see — a CLI killed
///    from outside, a machine that slept — and it is why nothing here depends
///    on an ending being reported.
/// 3. **Neither** — the claim stands, and the refusal names it.
///
/// A session whose status is `SessionStatus.unknown` is deliberately **not**
/// case 1. That word means "we lost sight of it", not "it ended", and treating
/// our own blind spot as a death is exactly the confident false statement §19
/// exists to delete. It holds the device until it goes quiet, like anybody
/// else.
///
/// [release] exists as well, so the ending the app *does* observe drops the
/// device at once rather than making the next agent wait out the lapse. It is
/// an optimisation on top of the two rules above, never a thing they rely on.
///
/// ## An unattributed caller respects a claim and never makes one
///
/// The launcher, or a bridge somebody started by hand, arrives with no session
/// id. It is still refused while another agent is driving — there must be no
/// side door around a holder — but it takes no claim of its own, because a
/// holder this app cannot name would produce precisely the anonymous refusal
/// this whole class exists to avoid. Two unattributed callers can therefore
/// still interleave; in practice they are the app itself and someone
/// debugging by hand, both of which the owner is driving directly.
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

  /// The claim on [deviceId] that is still standing, or null.
  ///
  /// Prunes as it reads, which is the whole of the expiry mechanism.
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

  /// Takes or renews [sessionId]'s claim on [deviceId] for [verb], or throws
  /// [DeviceBusy] naming whoever holds it.
  ///
  /// Called after the driver has resolved, so [deviceId] is the canonical id
  /// rather than whatever spelling the caller used — two agents naming one
  /// phone two ways must collide, not miss each other.
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

  /// Records that [sessionId] looked at [deviceId].
  ///
  /// Renews a claim the caller already holds and **never makes one**: reading a
  /// screen changes nothing, two agents can read one phone at the same moment
  /// without producing anything false, and locking a device by looking at it
  /// would make the refusal impossible to diagnose — a blocked agent needs to
  /// be able to see what the holder is doing to the device.
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

  /// The refusal. It names the holder, both readings carry their age, and it
  /// says what will clear it without anybody doing anything — a block whose end
  /// the reader cannot predict is the hang `SETTLED.md` refused leases over.
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

/// The app's one claim registry.
///
/// Its holder lookup is the same predicate `McpSessionTokenReaper` retires a
/// session's MCP token on — `Session.isOver` — so a session that has stopped
/// being speakable-for has also stopped holding phones. One rule, read from one
/// place.
final deviceClaimsProvider = Provider<DeviceClaims>(
  (ref) => DeviceClaims(
    clock: ref.watch(clockProvider),
    holder: (sessionId) {
      final session = ref.read(sessionDaoProvider).getById(sessionId);
      if (session == null || session.isOver) return null;
      return session.title;
    },
  ),
);
