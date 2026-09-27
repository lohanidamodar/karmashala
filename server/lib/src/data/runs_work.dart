import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

/// What answers the Flutter work a client asks of the server
/// (`FlutterWorkRequest`: the attached apps, a reload, a pick, an SDK
/// reading) — the server's Flutter loop, set once `serve` has built it.
abstract interface class FlutterWork {
  /// Does [request]'s work and answers it; throws [DataRefused].
  Future<Object?> handle(FlutterWorkRequest<Object?> request);

  /// What a client that has just subscribed is told at once: the attached
  /// apps and the runs still going.
  List<DataChange> greeting();
}

/// What answers the browser work a client asks of the server
/// (`BrowserWorkRequest`) — the server's browser, set once `serve` has built
/// it.
abstract interface class BrowserWork {
  /// Does [request]'s work and answers it; throws [DataRefused].
  Future<Object?> handle(BrowserWorkRequest<Object?> request);

  /// The browser as it stands, for a client that has just subscribed.
  List<DataChange> greeting();
}
