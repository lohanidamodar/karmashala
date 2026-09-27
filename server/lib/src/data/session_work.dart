import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

/// What answers the session work a client asks of the server
/// (`SessionWorkRequest`: a start, a resume, a handoff, a fork, an end) —
/// the server's one launch path, set once `serve` has built it.
abstract interface class SessionWork {
  /// Does [request]'s work and answers it; throws [DataRefused].
  Future<Object?> handle(SessionWorkRequest<Object?> request);
}
