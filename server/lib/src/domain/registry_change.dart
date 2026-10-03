import 'hosted_process.dart';
import 'package:karmashala_host_protocol/protocol.dart';

/// What the registry did to its set of processes. An exit is not one of
/// these: it is observed on [HostedProcess.ended], which a closed one also
/// reaches.
sealed class RegistryChange {
  const RegistryChange();
}

class SessionOpened extends RegistryChange {
  const SessionOpened(this.process);
  final HostedProcess process;
}

/// Ended and dropped because somebody asked, never because a client left.
class SessionClosed extends RegistryChange {
  const SessionClosed(
    this.process,
    this.end, {
    required this.endedByClose,
    this.reason,
  });
  final HostedProcess process;
  final SessionLifecycle end;

  /// Why the close was asked for when it is not a plain stop — an agent
  /// switch ([SessionEndedWithoutCode.switched]).
  final String? reason;

  /// Whether the close ended a running process. False when a client only let
  /// go of the record of a session that had already ended — a pane clearing
  /// away a leftover is not the person stopping it.
  final bool endedByClose;
}
