import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

/// What answers the SSH work a client asks of the server (`SshWorkRequest`:
/// a test connection, a disconnect, a prompt's answer) — the server's own
/// SSH, set once `serve` has built it.
abstract interface class SshWork {
  /// Does [request]'s work and answers it; throws [DataRefused].
  Future<Object?> handle(SshWorkRequest<Object?> request);

  /// What a client that has just subscribed is told at once: the
  /// connections that are not idle and the prompts still open.
  List<DataChange> greeting();
}
