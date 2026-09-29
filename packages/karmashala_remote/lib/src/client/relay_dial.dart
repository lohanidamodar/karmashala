import '../protocol.dart' show RendezvousId;
import '../transport/remote_transport.dart';

/// How many generations forward the companion probes when its counter and the
/// host's have drifted. Must stay within the host's own listen window.
const int kCompanionProbeWindow = 3;

/// Builds the relay transport for one rendezvous — a seam for tests.
typedef RelayTransportFactoryFn =
    RemoteTransport Function(Uri relay, RendezvousId rendezvous);
