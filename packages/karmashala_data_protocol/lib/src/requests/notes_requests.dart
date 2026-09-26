part of '../data_request.dart';

/// Every note newest first, or only those taken from [sessionId].
final class NotesList extends DataRequest<List<Note>> {
  const NotesList({this.sessionId});

  static const String name = 'notes.list';

  final String? sessionId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'sessionId': ?sessionId};

  @override
  Object? resultToJson(List<Note> result) => [
    for (final note in result) note.toJson(),
  ];

  @override
  List<Note> resultFromJson(Object? json) => _decode(kind, () {
    return [for (final item in _objects(json, kind)) Note.fromJson(item)];
  });
}

/// Keeps a note under the client's [id], its [body] exactly as given. With no
/// [projectId] and [inheritProject], the server files it under the project
/// of the repository it came from — [sourceRepositoryId], else the one the
/// server knows [sourceSessionId] by. Answers the note as stored.
final class NoteCapture extends DataRequest<Note> {
  const NoteCapture({
    required this.id,
    required this.body,
    this.title,
    this.projectId,
    this.inheritProject = true,
    this.sourceSessionId,
    this.sourceRepositoryId,
    this.sourceMessageOrdinal,
    this.sourceMessageRole,
  });

  factory NoteCapture._from(_Arguments args) => NoteCapture(
    id: args.string('id'),
    body: args.string('body'),
    title: args.optionalString('title'),
    projectId: args.optionalString('projectId'),
    inheritProject: args.boolean('inheritProject', orElse: true),
    sourceSessionId: args.optionalString('sourceSessionId'),
    sourceRepositoryId: args.optionalString('sourceRepositoryId'),
    sourceMessageOrdinal: args.optionalInt('sourceMessageOrdinal'),
    sourceMessageRole: args.optionalString('sourceMessageRole'),
  );

  static const String name = 'notes.capture';

  final String id;
  final String body;
  final String? title;
  final String? projectId;
  final bool inheritProject;
  final String? sourceSessionId;
  final String? sourceRepositoryId;
  final int? sourceMessageOrdinal;
  final String? sourceMessageRole;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'id': id,
    'body': body,
    'title': ?title,
    'projectId': ?projectId,
    'inheritProject': inheritProject,
    'sourceSessionId': ?sourceSessionId,
    'sourceRepositoryId': ?sourceRepositoryId,
    'sourceMessageOrdinal': ?sourceMessageOrdinal,
    'sourceMessageRole': ?sourceMessageRole,
  };

  @override
  Object? resultToJson(Note result) => result.toJson();

  @override
  Note resultFromJson(Object? json) =>
      _decode(kind, () => Note.fromJson(_object(json, kind)));
}

/// Rewrites what the person changed: the body, the title (blank clears it)
/// and the filing ([projectId] null is "no project", a choice).
final class NoteEdit extends DataRequest<Note> {
  const NoteEdit({
    required this.id,
    required this.body,
    this.title,
    this.projectId,
  });

  factory NoteEdit._from(_Arguments args) => NoteEdit(
    id: args.string('id'),
    body: args.string('body'),
    title: args.optionalString('title'),
    projectId: args.optionalString('projectId'),
  );

  static const String name = 'notes.edit';

  final String id;
  final String body;
  final String? title;
  final String? projectId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'id': id,
    'body': body,
    'title': ?title,
    'projectId': ?projectId,
  };

  @override
  Object? resultToJson(Note result) => result.toJson();

  @override
  Note resultFromJson(Object? json) =>
      _decode(kind, () => Note.fromJson(_object(json, kind)));
}

/// Files a note under [projectId], or unfiles it. Its text and `updatedAt`
/// stay: filing is not editing.
final class NoteFile extends DataRequest<Note> {
  const NoteFile({required this.id, this.projectId});

  static const String name = 'notes.file';

  final String id;
  final String? projectId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id, 'projectId': ?projectId};

  @override
  Object? resultToJson(Note result) => result.toJson();

  @override
  Note resultFromJson(Object? json) =>
      _decode(kind, () => Note.fromJson(_object(json, kind)));
}

/// Deletes a note. Refused [DataRefusalCode.notFound] when there is none.
final class NoteDelete extends DataRequest<DataAck> {
  const NoteDelete(this.id);

  static const String name = 'notes.delete';

  final String id;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id};

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}
