import 'data_change.dart';
import 'data_request.dart';
import 'refusal.dart';

/// How requests, answers and change batches travel: one JSON object each,
/// whatever carries it — a host-protocol frame today, a sealed companion
/// frame to a remote server later.
///
/// - request: `{id, kind, arguments}`
/// - answer: `{id, revision, result, changes?}` or `{id, refusal: {code,
///   message}}` — `changes` is everything the request wrote, its side
///   effects on other rows and domains included
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
    DataRequest<R> request,
    DataReply<R> reply,
  ) => {
    'id': id,
    'revision': reply.revision,
    'result': request.resultToJson(reply.value),
    if (reply.changes.isNotEmpty)
      'changes': [for (final change in reply.changes) change.toJson()],
  };

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
    final changes = json['changes'];
    return DataReply(request.resultFromJson(json['result']), revision, [
      if (changes is List)
        for (final change in changes)
          ?DataChange.fromJson((change as Map).cast<String, Object?>()),
    ]);
  }

  static Map<String, Object?> changes(DataChanges changes) => changes.toJson();

  static DataChanges readChanges(Map<String, Object?> json) =>
      DataChanges.fromJson(json);
}

/// A request's result, the server's revision when it was answered, and
/// every row the request changed — the same changes other clients are told.
final class DataReply<R> {
  const DataReply(this.value, this.revision, [this.changes = const []]);

  final R value;
  final int revision;
  final List<DataChange> changes;
}
