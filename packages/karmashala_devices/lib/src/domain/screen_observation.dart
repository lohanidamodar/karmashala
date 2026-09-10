import 'ui_node.dart';

/// The last time this app looked at one device's screen, and what it saw — the
/// evidence a coordinate is checked against, so "the screen has moved since you
/// looked" is something the app observes rather than the caller remembers.
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

/// A **structural** fingerprint of one screen: resource id, class and rectangle
/// of every node, in document order. **Text and content-description are
/// deliberately excluded** — a clock changes them several times a second — while
/// **bounds are included**, because a scroll leaves every label identical and
/// moves every rectangle. Rotation is folded in.
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

/// How long a read stays the read a coordinate plausibly came from. Beyond it a
/// **mismatch is a warning rather than a refusal**: a match never weakens with
/// age, but an old mismatch says nothing about where these numbers came from.
const Duration kDeviceLookWindow = Duration(minutes: 5);
