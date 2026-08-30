/// The Chitragupta relay: a zero-knowledge pipe between a desktop host and a
/// paired phone.
///
/// It pairs two outbound WebSockets by rendezvous id and forwards opaque
/// frames. It holds no accounts, no keys and no content, and cannot read what
/// it carries — every frame is sealed end to end before it arrives.
library;

export 'src/relay_server.dart'
    show
        RelayOptions,
        RelayServer,
        kCloseBusy,
        kCloseFrameTooLarge,
        kCloseImpatient,
        kCloseNoPeer,
        kClosePeerFailed,
        kClosePeerLeft,
        kDefaultConnectionsPerMinute,
        kDefaultLoneTimeout,
        kDefaultMaxFrameBytes,
        kDefaultMaxRendezvous,
        kDefaultPingInterval,
        kDefaultRelayPort,
        kMaxPendingFrames;
