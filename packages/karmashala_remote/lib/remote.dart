/// The wire itself: the frame protocol, the values that travel over it, and
/// the transports that carry it.
///
/// `protocol.dart` is the single definition of every frame type and its
/// encoding, shared by the desktop host and the phone; `domain/` holds the
/// payloads and presence values built on it, and `transport/` the LAN and
/// relay carriers plus the sealing that makes either one safe.
library;

export 'src/domain/companion_presence.dart';
export 'src/domain/paired_device.dart';
export 'src/domain/remote_payloads.dart';
export 'src/protocol.dart';
export 'src/transport/key_schedule.dart';
export 'src/transport/lan_beacon.dart';
export 'src/transport/lan_transport.dart';
export 'src/transport/relay_transport.dart';
export 'src/transport/remote_transport.dart';
export 'src/transport/sealed_channel.dart';
