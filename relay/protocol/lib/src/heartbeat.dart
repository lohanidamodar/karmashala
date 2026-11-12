/// The relay heartbeat: how a socket tells the relay it is still there, and
/// how a listener waiting for its peer stays past the lone timeout.
///
/// A text frame of exactly [kRelayPing] is answered to its sender with
/// [kRelayPong]. The relay never forwards it to the peer and never counts it
/// among the frames a lone socket may send before pairing. A lone socket
/// whose last ping is newer than [kRelayPingStaleAfter] when the lone timeout
/// comes round is left waiting; one that never pinged, or stopped, is dropped
/// with `kCloseNoPeer` as before.
///
/// Sealed frames are binary, so no frame of the app's can be mistaken for
/// either word. A relay that predates the heartbeat treats a ping as a frame
/// like any other — which is why a client stops pinging a relay that has not
/// answered its first.
library;

/// What a client sends.
const String kRelayPing = 'ping';

/// What the relay answers.
const String kRelayPong = 'pong';

/// How often a listener pings.
const Duration kRelayPingInterval = Duration(seconds: 25);

/// A socket's last ping is stale after this long: three missed heartbeats.
const Duration kRelayPingStaleAfter = Duration(seconds: 75);
