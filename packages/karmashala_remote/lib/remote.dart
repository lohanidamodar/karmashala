/// The wire itself: the frame protocol, the values that travel over it, and the
/// transports that carry it. `protocol.dart` is the single definition of every
/// frame type and its encoding, shared by the desktop host and the phone.
library;

export 'src/domain/companion_presence.dart';
export 'src/domain/paired_device.dart';
export 'src/domain/remote_notes.dart';
export 'src/domain/remote_payloads.dart';
export 'src/domain/remote_session_options.dart';
export 'src/domain/remote_usage.dart';
export 'src/protocol.dart';
export 'src/transport/key_schedule.dart';
export 'src/transport/lan_beacon.dart';
export 'src/transport/lan_transport.dart';
export 'src/transport/relay_transport.dart';
export 'src/transport/remote_transport.dart';
export 'src/transport/sealed_channel.dart';
export 'src/transport/stream_flow.dart';
