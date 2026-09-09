import 'package:agent_cli/process.dart';
import '../data/remote_file_browser.dart';
import '../data/ssh_connection.dart';
import '../domain/ssh_host_key.dart';

/// Digs the [HostKeyRejected] out of [error], however deeply it is wrapped.
///
/// A refused host key surfaces differently depending on who asked: the
/// connection wraps it in an `SshConnectionException`, a command runner wraps
/// *that* in a `CommandException`, and SFTP browsing wraps it again. All three
/// carry it as a cause, so one unwrap serves every caller and the UI never has
/// to string-match an error message to notice the one failure that matters most.
HostKeyRejected? hostKeyRejectionIn(Object? error) {
  var current = error;
  // Bounded so a cause cycle cannot hang the UI thread.
  for (var depth = 0; depth < 8 && current != null; depth++) {
    if (current is HostKeyRejected) return current;
    current = switch (current) {
      SshConnectionException e => e.cause,
      CommandException e => e.cause,
      RemoteBrowseException e => e.cause,
      _ => null,
    };
  }
  return null;
}

/// A message worth showing a user for [error].
///
/// Prefers the layer that actually knows what went wrong over the generic
/// wrapper around it, so "Authentication as dev@build-box was rejected" wins
/// over "Cannot run bash on dev@build-box:22". Never includes a credential:
/// every message it can return is one the SSH layer already deemed loggable.
String describeSshFailure(Object error) {
  final rejection = hostKeyRejectionIn(error);
  if (rejection != null) return rejection.presentation.describe();
  return switch (error) {
    SshConnectionException e => e.message,
    RemoteBrowseException e => e.message,
    CommandException e => switch (e.cause) {
      final SshConnectionException inner => inner.message,
      _ => e.message,
    },
    _ => error.toString(),
  };
}
