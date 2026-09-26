import 'data_change.dart';
import 'data_request.dart';
import 'refusal.dart';

/// How requests, answers and change batches travel: one JSON object each,
/// whatever carries it — a host-protocol frame today, a sealed companion
/// frame to a remote server later.
///
/// - request: `{id, kind, arguments}`
/// - answer: `{id, revision, result}` or `{id, refusal: {code, message}}`
/// - changes: `{revision, changes: [...]}`
abstract final class DataEnvelope {
  static Map<String, Object?> request(int id, DataRequest<Object?> request) => {
    'id': id,
    'kind': request.kind,
    'arguments': request.argumentsToJson(),
  };

  /// The request [json] carries, or the refusal to answer it with — under
  /// its id, or 0 when even that could not be read.
  static ({int id, DataRequest<Object?>? request, DataRefused? refusal})
  readRequest(Map<String, Object?> json) {
    final id = json['id'];
    final kind = json['kind'];
    final arguments = json['arguments'] ?? const <String, Object?>{};
    if (id is! int || kind is! String || arguments is! Map) {
      return (
        id: id is int ? id : 0,
        request: null,
        refusal: const DataRefused.invalid(
          'a data request is {id, kind, arguments}',
        ),
      );
    }
    try {
      return (
        id: id,
        request: DataRequest.fromJson(kind, arguments.cast<String, Object?>()),
        refusal: null,
      );
    } on DataRefused catch (refusal) {
      return (id: id, request: null, refusal: refusal);
    }
  }

  static Map<String, Object?> answer<R>(
    int id,
    int revision,
    DataRequest<R> request,
    R result,
  ) => {'id': id, 'revision': revision, 'result': request.resultToJson(result)};

  static Map<String, Object?> refusal(int id, DataRefused refusal) => {
    'id': id,
    'refusal': refusal.toJson(),
  };

  /// The id an answer [json] is for, or null when it names none.
  static int? answerId(Map<String, Object?> json) => json['id'] as int?;

  /// The reply [json] carries for [request], or throws the [DataRefused] it
  /// was refused with.
  static DataReply<R> readAnswer<R>(
    Map<String, Object?> json,
    DataRequest<R> request,
  ) {
    final refusal = json['refusal'];
    if (refusal is Map) {
      throw DataRefused.fromJson(refusal.cast<String, Object?>());
    }
    final revision = json['revision'];
    if (revision is! int) {
      throw DataRefused(
        DataRefusalCode.failed,
        'the server answered ${request.kind} without a revision',
      );
    }
    return DataReply(request.resultFromJson(json['result']), revision);
  }

  static Map<String, Object?> changes(DataChanges changes) => changes.toJson();

  static DataChanges readChanges(Map<String, Object?> json) =>
      DataChanges.fromJson(json);
}

/// A request's result, and the server's revision when it was answered.
final class DataReply<R> {
  const DataReply(this.value, this.revision);

  final R value;
  final int revision;
}
