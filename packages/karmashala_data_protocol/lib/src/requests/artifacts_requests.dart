part of '../data_request.dart';

DataRequest<Object?>? _artifactsRequestFromJson(
  String kind,
  _Arguments args,
) => switch (kind) {
  SessionArtifactsRead.name => SessionArtifactsRead(args.string('sessionId')),
  ArtifactRevisionsRead.name => ArtifactRevisionsRead(args.string('id')),
  ArtifactContentRead.name => ArtifactContentRead(
    args.string('id'),
    revision: args.optionalInt('revision'),
    offset: args.optionalInt('offset') ?? 0,
    length: args.optionalInt('length') ?? kFileChunkBytes,
  ),
  ArtifactSetNetwork.name => ArtifactSetNetwork(
    args.string('id'),
    allowed: args.boolean('allowed'),
  ),
  _ => null,
};

/// A request about what agents showed in their threads. Content is the
/// server's snapshot of a revision, served in chunks like `files.read` — a
/// client is never handed the host path it came from. Answered when the
/// disk has been read.
sealed class ArtifactsRequest<R> extends DataRequest<R> {
  const ArtifactsRequest();
}

/// [sessionId]'s artifacts, oldest first.
final class SessionArtifactsRead extends ArtifactsRequest<List<Artifact>> {
  const SessionArtifactsRead(this.sessionId);

  static const String name = 'artifacts.forSession';

  final String sessionId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'sessionId': sessionId};

  @override
  Object? resultToJson(List<Artifact> result) => [
    for (final a in result) artifactToClientJson(a),
  ];

  @override
  List<Artifact> resultFromJson(Object? json) => _decode(
    kind,
    () => [for (final item in _objects(json, kind)) artifactFromJson(item)],
  );
}

/// The revisions of artifact [id] still kept, oldest first.
final class ArtifactRevisionsRead
    extends ArtifactsRequest<List<ArtifactRevisionSummary>> {
  const ArtifactRevisionsRead(this.id);

  static const String name = 'artifacts.revisions';

  final String id;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id};

  @override
  Object? resultToJson(List<ArtifactRevisionSummary> result) => [
    for (final r in result) r.toJson(),
  ];

  @override
  List<ArtifactRevisionSummary> resultFromJson(Object? json) => _decode(
    kind,
    () => [
      for (final item in _objects(json, kind))
        ArtifactRevisionSummary.fromJson(item),
    ],
  );
}

/// Up to [length] bytes of artifact [id] at [revision] — the newest when
/// null — from [offset].
final class ArtifactContentRead extends ArtifactsRequest<FileChunk> {
  const ArtifactContentRead(
    this.id, {
    this.revision,
    this.offset = 0,
    this.length = kFileChunkBytes,
  });

  static const String name = 'artifacts.content';

  final String id;
  final int? revision;
  final int offset;
  final int length;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'id': id,
    'revision': ?revision,
    'offset': offset,
    'length': length,
  };

  @override
  Object? resultToJson(FileChunk result) => result.toJson();

  @override
  FileChunk resultFromJson(Object? json) =>
      _decode(kind, () => FileChunk.fromJson(_object(json, kind)));
}

/// Lets artifact [id] reach the network, or takes that back. Every client
/// shares the one setting, so allowing it on a desktop allows it on a phone.
final class ArtifactSetNetwork extends ArtifactsRequest<Artifact> {
  const ArtifactSetNetwork(this.id, {required this.allowed});

  static const String name = 'artifacts.setNetwork';

  final String id;
  final bool allowed;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id, 'allowed': allowed};

  @override
  Object? resultToJson(Artifact result) => artifactToClientJson(result);

  @override
  Artifact resultFromJson(Object? json) =>
      _decode(kind, () => artifactFromJson(_object(json, kind)));
}
