import 'host_session.dart';
import 'session_lifecycle.dart';

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
  const SessionClosed(this.session, this.end);
  final HostSession session;
  final SessionLifecycle end;
}
