/// The Karmashala relay: a zero-knowledge pipe between a desktop host and a
/// paired phone.
///
/// It pairs two outbound WebSockets by rendezvous id and forwards opaque
/// frames. It holds no accounts, no keys and no content, and cannot read what
/// it carries — every frame is sealed end to end before it arrives.
///
/// What it accepts and answers — routes, rendezvous and token rules, push
/// bodies, status and close codes — is `package:karmashala_relay_protocol`.
library;

export 'src/fcm_sender.dart' show FcmHttpV1Sender, kServiceAccountEnvVar;
export 'src/push_delivery.dart'
    show PushDelivery, PushDeliveryException, PushTokenGoneException;
export 'src/relay_server.dart'
    show
        RelayOptions,
        RelayServer,
        kDefaultConnectionsPerMinute,
        kDefaultLoneTimeout,
        kDefaultMaxFrameBytes,
        kDefaultMaxHookListeners,
        kDefaultMaxPushPayloadBytes,
        kDefaultMaxPushTokens,
        kDefaultMaxRendezvous,
        kDefaultPingInterval,
        kMaxPendingFrames,
        hooksListenIdOf;
