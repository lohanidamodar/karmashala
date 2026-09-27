import 'data_change.dart';
import 'data_envelope.dart';
import 'data_request.dart';
import 'data_stream.dart';

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

  /// A live stream of [source]'s [key] (`kFlutterLogsStream`): opened on
  /// listen, closed on cancel; its backlog comes first. Ends with the link,
  /// and errors with [DataRefused] when the server will not open it.
  Stream<DataStreamItems> openStream(String source, String key);

  /// Completes when the link ends, from either side.
  Future<void> get done;

  Future<void> close();
}
