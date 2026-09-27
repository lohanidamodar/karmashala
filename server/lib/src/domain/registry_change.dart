import 'host_session.dart';
import 'package:karmashala_host_protocol/protocol.dart';

/// What the registry did to its set of sessions. An exit is not one of these:
/// it is observed on [HostSession.ended], which a closed session also reaches.
sealed class RegistryChange {
  const RegistryChange();
}

class SessionOpened extends RegistryChange {
  const SessionOpened(this.session);
  final HostSession session;
}

/// Ended and dropped because somebody asked, never because a client left.
class SessionClosed extends RegistryChange {
  const SessionClosed(this.session, this.end, {required this.endedByClose});
  final HostSession session;
  final SessionLifecycle end;

  /// Whether the close ended a running process. False when a client only let
  /// go of the record of a session that had already ended — a pane clearing
  /// away a leftover is not the person stopping it.
  final bool endedByClose;
}
