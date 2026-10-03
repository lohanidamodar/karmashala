part of '../data_request.dart';

// A session's delegates, gathered on the server: the subagents its agent's
// record names and the sessions that name it as their parent. An older
// server refuses the kind as `invalid`.

DataRequest<Object?>? _sessionSubagentsRequestFromJson(
  String kind,
  _Arguments args,
) => switch (kind) {
  SessionSubagentsRead.name => SessionSubagentsRead(args.string('sessionId')),
  _ => null,
};

/// Session [sessionId]'s subagents and child sessions, with each one's state,
/// timing, tokens and last answer.
final class SessionSubagentsRead
    extends SessionTranscriptRequest<SessionSubagentList> {
  const SessionSubagentsRead(this.sessionId);

  static const String name = 'sessions.subagents';

  final String sessionId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'sessionId': sessionId};

  @override
  Object? resultToJson(SessionSubagentList result) => result.toJson();

  @override
  SessionSubagentList resultFromJson(Object? json) =>
      _decode(kind, () => SessionSubagentList.fromJson(_object(json, kind)));
}
