part of '../data_request.dart';

// A session's transcript read where its agent wrote it (Stage 0 step 5): the
// server's machine, so a client on another one draws the same chat. Pull on
// notice: a watching link is told `transcriptChanged` and fetches from its
// cursor, so a reconnect is one fetch and nothing is ever dropped. Each reads
// a disk, so each is answered when done (`DataSession.handleLater`).
//
// Refusals: `denied` for a link whose pairing does not grant reading
// transcripts, `unavailable` for a server that serves none. A session with no
// record is not refused: its page says why (`absence`).

DataRequest<Object?>? _sessionTranscriptRequestFromJson(
  String kind,
  _Arguments args,
) => switch (kind) {
  SessionTranscriptRead.name => SessionTranscriptRead(
    args.string('sessionId'),
    after: args.optionalInt('after'),
    before: args.optionalInt('before'),
    limit: args.optionalInt('limit'),
    generation: args.optionalString('generation'),
    revision: args.optionalInt('revision'),
  ),
  SessionTranscriptWatch.name => SessionTranscriptWatch(
    args.string('sessionId'),
  ),
  SessionTranscriptUnwatch.name => SessionTranscriptUnwatch(
    args.string('sessionId'),
  ),
  _ => null,
};

/// A session's transcript, read on the server; answered when done.
sealed class SessionTranscriptRequest<R> extends DataRequest<R> {
  const SessionTranscriptRequest();

  /// A session row's id or an imported session's.
  String get sessionId;
}

/// One page of session [sessionId]'s transcript.
///
/// - No cursor: the tail, up to [limit] messages back.
/// - [after] with the [generation] and [revision] last answered: the rows
///   from index [after] on, plus `updates` for rows below it that changed
///   since. Another generation, or a revision the server never answered, is
///   answered `reset` with the tail.
/// - [before]: the [limit] rows before that index, for scrolling back.
final class SessionTranscriptRead
    extends SessionTranscriptRequest<TranscriptPage> {
  const SessionTranscriptRead(
    this.sessionId, {
    this.after,
    this.before,
    this.limit,
    this.generation,
    this.revision,
  });

  static const String name = 'sessions.transcript';

  @override
  final String sessionId;
  final int? after;
  final int? before;
  final int? limit;
  final String? generation;
  final int? revision;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'sessionId': sessionId,
    'after': ?after,
    'before': ?before,
    'limit': ?limit,
    'generation': ?generation,
    'revision': ?revision,
  };

  @override
  Object? resultToJson(TranscriptPage result) => result.toJson();

  @override
  TranscriptPage resultFromJson(Object? json) =>
      _decode(kind, () => TranscriptPage.fromJson(_object(json, kind)));
}

/// Tells **this link** — no other — a [TranscriptChanged] each time session
/// [sessionId]'s transcript moves, until [SessionTranscriptUnwatch] or the
/// link closes. Answered once the server has read it as it stands.
final class SessionTranscriptWatch extends SessionTranscriptRequest<DataAck> {
  const SessionTranscriptWatch(this.sessionId);

  static const String name = 'sessions.transcript.watch';

  @override
  final String sessionId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'sessionId': sessionId};

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}

/// Stops [SessionTranscriptWatch] for [sessionId] on this link.
final class SessionTranscriptUnwatch extends SessionTranscriptRequest<DataAck> {
  const SessionTranscriptUnwatch(this.sessionId);

  static const String name = 'sessions.transcript.unwatch';

  @override
  final String sessionId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'sessionId': sessionId};

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}
