import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

/// What answers a client's `bot.*` requests: the server's bot, set once `serve`
/// has built it.
abstract interface class BotWork {
  /// Answers [request] for paired [device], null on this machine; throws
  /// [DataRefused].
  Future<Object?> handle(BotRequest<Object?> request, {String? device});
}
