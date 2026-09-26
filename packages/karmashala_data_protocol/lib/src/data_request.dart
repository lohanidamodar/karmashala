import 'package:karmashala_notes/karmashala_notes.dart';

import 'refusal.dart';

part 'requests/subscription_requests.dart';
part 'requests/notes_requests.dart';
part 'requests/todos_requests.dart';
part 'requests/preferences_requests.dart';

/// One question or change a client asks of a server's data, answered with an
/// [R] or refused with [DataRefused]. Typed per domain: no SQL crosses.
sealed class DataRequest<R> {
  const DataRequest();

  /// The request's name on the wire, `<domain>.<verb>`.
  String get kind;

  Map<String, Object?> argumentsToJson();

  Object? resultToJson(R result);

  /// Throws [DataRefused] ([DataRefusalCode.failed]) on an answer that is
  /// not an [R] — a server of another build.
  R resultFromJson(Object? json);

  /// The request [kind] names. Throws [DataRefused.invalid] for an unknown
  /// kind or arguments that do not fit it.
  static DataRequest<Object?> fromJson(
    String kind,
    Map<String, Object?> arguments,
  ) {
    final args = _Arguments(kind, arguments);
    return switch (kind) {
      DataSubscribe.name => const DataSubscribe(),
      NotesList.name => NotesList(sessionId: args.optionalString('sessionId')),
      NoteCapture.name => NoteCapture._from(args),
      NoteEdit.name => NoteEdit._from(args),
      NoteFile.name => NoteFile(
        id: args.string('id'),
        projectId: args.optionalString('projectId'),
      ),
      NoteDelete.name => NoteDelete(args.string('id')),
      TodosList.name => const TodosList(),
      TodoAdd.name => TodoAdd._from(args),
      TodoSetDone.name => TodoSetDone(
        id: args.string('id'),
        done: args.boolean('done'),
      ),
      TodoEdit.name => TodoEdit(
        id: args.string('id'),
        body: args.string('body'),
      ),
      TodoFile.name => TodoFile(
        id: args.string('id'),
        projectId: args.optionalString('projectId'),
      ),
      TodoMove.name => TodoMove(id: args.string('id'), up: args.boolean('up')),
      TodoDelete.name => TodoDelete(args.string('id')),
      TodosClearDone.name => TodosClearDone(args.strings('ids')),
      PreferencesGet.name => const PreferencesGet(),
      PreferenceSet.name => PreferenceSet(
        args.string('key'),
        args.string('value'),
      ),
      PreferenceRemove.name => PreferenceRemove(args.string('key')),
      _ => throw DataRefused.invalid('no data request is called "$kind"'),
    };
  }

  @override
  String toString() => 'DataRequest($kind)';
}

/// The answer to a request that changes something and reports nothing more.
final class DataAck {
  const DataAck();
}

/// Reads one request's arguments, refusing what does not fit.
final class _Arguments {
  _Arguments(this.kind, this.values);

  final String kind;
  final Map<String, Object?> values;

  String string(String key) {
    final value = values[key];
    if (value is String) return value;
    throw DataRefused.invalid('$kind: "$key" must be a string');
  }

  String? optionalString(String key) {
    final value = values[key];
    if (value == null || value is String) return value as String?;
    throw DataRefused.invalid('$kind: "$key" must be a string or absent');
  }

  int? optionalInt(String key) {
    final value = values[key];
    if (value == null || value is int) return value as int?;
    throw DataRefused.invalid('$kind: "$key" must be a whole number or absent');
  }

  bool boolean(String key, {bool? orElse}) {
    final value = values[key];
    if (value is bool) return value;
    if (value == null && orElse != null) return orElse;
    throw DataRefused.invalid('$kind: "$key" must be true or false');
  }

  List<String> strings(String key) {
    final value = values[key];
    if (value is List && value.every((item) => item is String)) {
      return value.cast<String>();
    }
    throw DataRefused.invalid('$kind: "$key" must be a list of strings');
  }
}

Never _badAnswer(String kind) => throw DataRefused(
  DataRefusalCode.failed,
  'the server answered $kind with something this client cannot read',
);

Map<String, Object?> _object(Object? json, String kind) =>
    json is Map ? json.cast<String, Object?>() : _badAnswer(kind);

List<Map<String, Object?>> _objects(Object? json, String kind) => json is List
    ? [for (final item in json) _object(item, kind)]
    : _badAnswer(kind);

T _decode<T>(String kind, T Function() read) {
  try {
    return read();
  } on DataRefused {
    rethrow;
  } on Object {
    _badAnswer(kind);
  }
}
