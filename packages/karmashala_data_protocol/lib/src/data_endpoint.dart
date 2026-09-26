import 'data_change.dart';
import 'data_envelope.dart';
import 'data_request.dart';

/// Where a client sends its data requests: a server over some link. The
/// client's code sees only this, so a local server and a remote one are the
/// same to it.
abstract interface class DataEndpoint {
  /// Answers [request], or throws [DataRefused] — with
  /// [DataRefusalCode.unavailable] when no server answers.
  Future<DataReply<R>> send<R>(DataRequest<R> request);

  /// The changes other clients made, once [DataSubscribe] was sent. Ends
  /// when the link does.
  Stream<DataChanges> get changes;

  /// Completes when the link ends, from either side.
  Future<void> get done;

  Future<void> close();
}
