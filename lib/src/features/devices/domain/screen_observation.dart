import 'ui_node.dart';

/// The last time this app looked at one device's screen, and what it saw.
///
/// The evidence a coordinate is checked against. `device_tap` takes numbers a
/// caller worked out earlier; this is the record of the screen those numbers
/// could plausibly have come from, so "the screen has moved since you looked"
/// becomes something the app can *observe* rather than something the caller
/// has to remember.
class ScreenObservation {
  const ScreenObservation({
    required this.deviceId,
    required this.fingerprint,
    required this.app,
    required this.nodeCount,
    required this.at,
    required this.bySessionId,
  });

  final String deviceId;

  /// See [fingerprintOfScreen].
  final int fingerprint;

  /// The foreground app: a package name on Android, a bundle id on iOS.
  final String? app;

  final int nodeCount;

  final DateTime at;

  /// Which session read it, for the sentence. Null for the launcher's own
  /// reads and for a bridge somebody started by hand.
  final String? bySessionId;

  /// Whether [other] is the same screen as this one.
  bool matches(ScreenObservation other) =>
      other.fingerprint == fingerprint && other.app == app;

  /// What differs, in the words a refusal uses. Empty when nothing does.
  String differenceFrom(ScreenObservation earlier) {
    if (app != earlier.app) {
      return '${earlier.app ?? 'an unknown app'} was in front then and '
          '${app ?? 'an unknown app'} is now';
    }
    if (nodeCount != earlier.nodeCount) {
      return 'the hierarchy had ${earlier.nodeCount} nodes then and has '
          '$nodeCount now';
    }
    return 'the same nodes are in different places — something moved, '
        'scrolled or was replaced';
  }
}

/// A **structural** fingerprint of one screen: resource id, class and
/// rectangle of every node, in document order.
///
/// **Text and content-description are deliberately excluded.** A clock, a
/// counter, a progress label, a streaming response and a relative timestamp all
/// change their text several times a second while the screen an agent is aiming
/// at has not moved at all. Folding those in would make every coordinate tap on
/// a live screen fail the check, and a check that fails on working screens is a
/// check somebody turns off — which is the failure mode this whole safety net
/// is written to avoid.
///
/// **Bounds are included, and that is the point.** A scroll leaves every label
/// identical and moves every rectangle, and a coordinate computed before a
/// scroll is precisely the stale coordinate this exists to catch. So is a
/// dialog appearing: new nodes, new rectangles, whatever the text says.
///
/// Rotation is folded in because a rotated screen is a different screen even
/// when the tree happens to survive it.
int fingerprintOfScreen(UiHierarchy tree) {
  var hash = tree.rotation.hashCode;
  for (final node in tree.allNodes) {
    hash = Object.hash(
      hash,
      node.resourceId,
      node.className,
      node.bounds?.raw ?? '',
    );
  }
  return hash;
}

/// How long a read stays the read a coordinate plausibly came from.
///
/// Beyond this a **mismatch is a warning rather than a refusal**, and the
/// asymmetry is deliberate. A match never weakens with age: if the structure is
/// byte-for-byte what we saw an hour ago, the screen has not moved, and that is
/// as good an answer today as it was then. A *mismatch* does weaken — an
/// hour-old reading that differs says nothing about where these particular
/// numbers came from, because the caller may have measured them off a
/// screenshot, been handed them by the user, or been working on something else
/// entirely since. Refusing on that is refusing on a guess, and refusals built
/// on guesses are how a safety net gets a reputation for being in the way.
///
/// Five minutes: long enough to cover a look, a think and a tap; short enough
/// that it does not span a change of subject.
const Duration kDeviceLookWindow = Duration(minutes: 5);
