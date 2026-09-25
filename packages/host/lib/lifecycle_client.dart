/// Watching a host's session lifecycle, for any Dart client. No `dart:ffi` and
/// no Flutter, like `protocol.dart`.
library;

export 'src/client/lifecycle_watch.dart';
export 'src/protocol/messages.dart'
    show
        HostSessionFacts,
        HostSessionState,
        LifecycleEvent,
        LifecycleEventKind,
        WelcomeMessage;
export 'src/transport/socket_transport.dart' show SocketHostConnection;
export 'src/transport/transport.dart' show HostConnection;
