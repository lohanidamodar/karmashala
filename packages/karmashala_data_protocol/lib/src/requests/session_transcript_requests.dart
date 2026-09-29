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
    digest: args.optionalInt('digest'),
  ),
  SessionTranscriptTurns.name => SessionTranscriptTurns(
    args.string('sessionId'),
    before: args.optionalInt('before'),
    limit: args.optionalInt('limit'),
    generation: args.optionalString('generation'),
    spoken: args.boolean('spoken', orElse: false),
  ),
  SessionTranscriptWatch.name => SessionTranscriptWatch(
    args.string('sessionId'),
  ),
  SessionTranscriptUnwatch.name => SessionTranscriptUnwatch(
    args.string('sessionId'),
  ),
  SessionTranscriptSubagent.name => SessionTranscriptSubagent(
    args.string('sessionId'),
    args.string('path'),
    after: args.optionalInt('after'),
    limit: args.optionalInt('limit'),
  ),
  SessionRewindPointsRead.name => SessionRewindPointsRead(
    args.string('sessionId'),
  ),
  SessionChangedFilesRead.name => SessionChangedFilesRead(
    args.string('sessionId'),
  ),
  SessionOpenQuestionRead.name => SessionOpenQuestionRead(
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
/// - [digest], the first row this client holds (Stage 0 step 8): the page
///   also answers `digest` for the rows before the window the client holds
///   once it has read this page. An older server ignores it.
final class SessionTranscriptRead
    extends SessionTranscriptRequest<TranscriptPage> {
  const SessionTranscriptRead(
    this.sessionId, {
    this.after,
    this.before,
    this.limit,
    this.generation,
    this.revision,
    this.digest,
  });

  static const String name = 'sessions.transcript';

  @override
  final String sessionId;
  final int? after;
  final int? before;
  final int? limit;
  final String? generation;
  final int? revision;
  final int? digest;

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
    'digest': ?digest,
  };

  @override
  Object? resultToJson(TranscriptPage result) => result.toJson();

  @override
  TranscriptPage resultFromJson(Object? json) =>
      _decode(kind, () => TranscriptPage.fromJson(_object(json, kind)));
}

/// One page of session [sessionId]'s turns as text only — role, text and
/// time, no thinking and no tool detail (Stage 0 step 8): what an export or
/// a recap quotes, at a fraction of [SessionTranscriptRead]'s bytes.
///
/// [spoken] keeps only user and agent turns that say something; `total` and
/// `from` then count those. No cursor answers the tail; [before] with the
/// [generation] last answered pages back. Another generation is answered
/// `reset` with the tail. An older server refuses the kind as `invalid`.
final class SessionTranscriptTurns
    extends SessionTranscriptRequest<TranscriptPage> {
  const SessionTranscriptTurns(
    this.sessionId, {
    this.before,
    this.limit,
    this.generation,
    this.spoken = false,
  });

  static const String name = 'sessions.transcript.turns';

  @override
  final String sessionId;
  final int? before;
  final int? limit;
  final String? generation;
  final bool spoken;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'sessionId': sessionId,
    'before': ?before,
    'limit': ?limit,
    'generation': ?generation,
    if (spoken) 'spoken': true,
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

/// One page of a subagent's turns (Stage 0 step 6): the delegate a `Task` row
/// of session [sessionId] spawned, whose transcript is at [path] on the
/// server's machine (`SubagentRef.filePath`). Read whole each time, for the
/// row a person expanded; [after] (default 0) and [limit] page forward, so a
/// client asks again while the page `hasNewer`.
///
/// Refused `invalid` for a [path] that is not one of [sessionId]'s
/// subagents: the request reads no other file. An older server refuses the
/// kind as `invalid` too; a client then reads its own disk, as before.
final class SessionTranscriptSubagent
    extends SessionTranscriptRequest<TranscriptPage> {
  const SessionTranscriptSubagent(
    this.sessionId,
    this.path, {
    this.after,
    this.limit,
  });

  static const String name = 'sessions.transcript.subagent';

  @override
  final String sessionId;
  final String path;
  final int? after;
  final int? limit;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'sessionId': sessionId,
    'path': path,
    'after': ?after,
    'limit': ?limit,
  };

  @override
  Object? resultToJson(TranscriptPage result) => result.toJson();

  @override
  TranscriptPage resultFromJson(Object? json) =>
      _decode(kind, () => TranscriptPage.fromJson(_object(json, kind)));
}

// The readers of raw record lines (Stage 0 step 7): each runs the agent
// adapter's own code where the record is, and answers its result. An older
// server refuses each kind as `invalid`; a client then reads its own disk.

/// The agent's own rewind points for session [sessionId]
/// (`OwnRewindPoints.parse`), or null when its agent keeps none or its
/// record could not be read.
final class SessionRewindPointsRead
    extends SessionTranscriptRequest<AgentRewindPoints?> {
  const SessionRewindPointsRead(this.sessionId);

  static const String name = 'sessions.rewindPoints';

  @override
  final String sessionId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'sessionId': sessionId};

  @override
  Object? resultToJson(AgentRewindPoints? result) => result?.toJson();

  @override
  AgentRewindPoints? resultFromJson(Object? json) => json == null
      ? null
      : _decode(kind, () => AgentRewindPoints.fromJson(_object(json, kind)));
}

/// The files session [sessionId]'s agent recorded changing: its transcript's
/// edits (`TranscriptFileEdits`) or its store server's answer.
final class SessionChangedFilesRead
    extends SessionTranscriptRequest<AgentFileChangesReading> {
  const SessionChangedFilesRead(this.sessionId);

  static const String name = 'sessions.changedFiles';

  @override
  final String sessionId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'sessionId': sessionId};

  @override
  Object? resultToJson(AgentFileChangesReading result) => result.toJson();

  @override
  AgentFileChangesReading resultFromJson(Object? json) => _decode(
    kind,
    () => AgentFileChangesReading.fromJson(_object(json, kind)),
  );
}

/// The question session [sessionId]'s agent has open in the tail of its
/// record (`openQuestionIn`), or null.
final class SessionOpenQuestionRead
    extends SessionTranscriptRequest<AgentQuestionSet?> {
  const SessionOpenQuestionRead(this.sessionId);

  static const String name = 'sessions.openQuestion';

  @override
  final String sessionId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'sessionId': sessionId};

  @override
  Object? resultToJson(AgentQuestionSet? result) =>
      result == null ? null : questionToJson(result);

  @override
  AgentQuestionSet? resultFromJson(Object? json) =>
      json == null ? null : _decode(kind, () => questionFromJson(json));
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
