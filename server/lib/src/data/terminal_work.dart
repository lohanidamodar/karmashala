import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

/// What answers the terminal work a client asks of the server
/// (`TerminalWorkRequest`: the profiles, a start, the list, a close, a
/// rename) — the server's terminals, set once `serve` has built them.
abstract interface class TerminalWork {
  /// Does [request]'s work and answers it; throws [DataRefused].
  Future<Object?> handle(TerminalWorkRequest<Object?> request);

  /// What a client that has just subscribed is told at once: every terminal
  /// the server holds.
  List<DataChange> greeting();
}
