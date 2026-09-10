import 'package:agent_cli/process.dart';
import 'package:karmashala_ssh/files.dart';
import 'package:karmashala_ssh/connection.dart';

/// Digs the [HostKeyRejected] out of [error], however deeply wrapped, so the UI
/// never string-matches an error message to find the one failure that matters.
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

/// A message worth showing a user for [error], from the layer that knows what
/// went wrong. Never a credential: every message is already deemed loggable.
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
