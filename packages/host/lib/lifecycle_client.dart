/// Watching a host's session lifecycle, for any Dart client. No `dart:ffi` and
/// no Flutter, like `protocol.dart`.
library;

export 'src/client/lifecycle_watch.dart';
export 'src/hooks/hook_endpoint_file.dart';
export 'src/hooks/hook_server.dart' show kHookSessionHeader;
export 'src/protocol/messages.dart'
    show
        AgentHookEvent,
        HostSessionFacts,
        HostSessionState,
        LifecycleEvent,
        LifecycleEventKind,
        SessionChangedMessage,
        WelcomeMessage;
export 'src/transport/socket_transport.dart' show SocketHostConnection;
export 'src/transport/transport.dart' show HostConnection;
