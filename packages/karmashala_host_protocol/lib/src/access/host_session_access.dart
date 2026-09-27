import 'host_deployment.dart';
import 'remote_channel.dart';

/// Everything a link needs from one machine's session host: whether it
/// answers, and a channel to speak the protocol over. This machine's server
/// (the client's `LocalHostSessionAccess`) and a box the server deployed to
/// (`SshHostSessionAccess`) are both one.
abstract class HostSessionAccess {
  String get address;

  /// The reading for this host, taken once per connection and shared. It
  /// carries the time it was taken, so a caller can say how old it is.
  Future<HostDeployment> deployment();

  /// A channel to speak the host protocol over.
  Future<RemoteChannel> exec(String command);

  /// Fires each time the connection to this machine is re-established after
  /// having dropped. A link re-dials on this; nothing polls for it.
  Stream<void> get reconnected;
}
