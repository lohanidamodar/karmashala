part of '../data_request.dart';

/// The whole sessions domain a client copies: rows, their checkouts, the
/// imported history, decisions, recaps and follow-ups.
final class SessionsList extends DataRequest<SessionsSnapshot> {
  const SessionsList();

  static const String name = 'sessions.list';

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => const {};

  @override
  Object? resultToJson(SessionsSnapshot result) => result.toJson();

  @override
  SessionsSnapshot resultFromJson(Object? json) =>
      _decode(kind, () => SessionsSnapshot.fromJson(_object(json, kind)));
}

/// Records a session under the client's id, linked to its repository as the
/// primary checkout and to each of [repositories] beside it, in one
/// transaction: a row no list can place is never left behind. Refused for a
/// taken or malformed id, a blank title, and a repository, agent installation
/// or parent the server does not know.
final class SessionCreate extends _SessionWrite {
  const SessionCreate(this.session, {this.repositories = const []});

  static const String name = 'sessions.create';

  final Session session;

  /// Checkouts beside the primary one.
  final List<String> repositories;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'session': session.toJson(),
    if (repositories.isNotEmpty) 'repositories': repositories,
  };
}

/// Writes the columns [patch] names on a session. A status is ignored while
/// the server runs that session: its lifecycle is the server's to record.
/// Refused for an unknown session and a blank title.
final class SessionEdit extends _SessionWrite {
  const SessionEdit(this.id, this.patch);

  static const String name = 'sessions.edit';

  final String id;
  final SessionPatch patch;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'id': id,
    'patch': patch.toJson(),
  };
}

/// Deletes a session and everything recorded against it — told as changes.
final class SessionDelete extends _AckRequest {
  const SessionDelete(this.id);

  static const String name = 'sessions.delete';

  final String id;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id};
}

/// Adds a checkout to a session, beside its primary one. Answers the
/// session's links. Refused for a checkout of another project.
final class SessionLinkAdd extends _LinksRequest {
  const SessionLinkAdd({required this.sessionId, required this.repositoryId});

  static const String name = 'sessions.link';

  final String sessionId;
  final String repositoryId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'sessionId': sessionId,
    'repositoryId': repositoryId,
  };
}

/// Takes a checkout off a session; the primary one stays. Answers the
/// session's links.
final class SessionLinkRemove extends _LinksRequest {
  const SessionLinkRemove({
    required this.sessionId,
    required this.repositoryId,
  });

  static const String name = 'sessions.unlink';

  final String sessionId;
  final String repositoryId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'sessionId': sessionId,
    'repositoryId': repositoryId,
  };
}

/// A session's event log, in append order.
final class SessionEvents extends DataRequest<List<SessionEvent>> {
  const SessionEvents(this.sessionId);

  static const String name = 'sessions.events';

  final String sessionId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'sessionId': sessionId};

  @override
  Object? resultToJson(List<SessionEvent> result) => [
    for (final event in result) event.toJson(),
  ];

  @override
  List<SessionEvent> resultFromJson(Object? json) => _decode(kind, () {
    return [
      for (final item in _objects(json, kind)) SessionEvent.fromJson(item),
    ];
  });
}

/// When the newest event of any of [sessionIds] was written, or null for
/// none.
final class SessionEventsLatest extends DataRequest<DateTime?> {
  const SessionEventsLatest(this.sessionIds);

  static const String name = 'sessions.lastEventAt';

  final List<String> sessionIds;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'sessionIds': sessionIds};

  @override
  Object? resultToJson(DateTime? result) => result?.toUtc().toIso8601String();

  @override
  DateTime? resultFromJson(Object? json) => json == null
      ? null
      : _decode(kind, () => DateTime.parse(json as String).toUtc());
}

/// Appends [events] to their sessions' logs in order, each given the next
/// sequence number there; answers them as stored. Refused whole for an
/// unknown session.
final class SessionEventsAppend extends DataRequest<List<SessionEvent>> {
  const SessionEventsAppend(this.events);

  static const String name = 'sessions.appendEvents';

  final List<SessionEvent> events;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'events': [for (final event in events) event.toJson()],
  };

  @override
  Object? resultToJson(List<SessionEvent> result) => [
    for (final event in result) event.toJson(),
  ];

  @override
  List<SessionEvent> resultFromJson(Object? json) => _decode(kind, () {
    return [
      for (final item in _objects(json, kind)) SessionEvent.fromJson(item),
    ];
  });
}

/// Appends a decision to its session's record, next in sequence; answers it
/// as stored. Refused for an unknown session and a blank summary.
final class DecisionAppend extends DataRequest<DecisionRecord> {
  const DecisionAppend(this.decision);

  static const String name = 'sessions.recordDecision';

  final DecisionRecord decision;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'decision': decision.toJson()};

  @override
  Object? resultToJson(DecisionRecord result) => result.toJson();

  @override
  DecisionRecord resultFromJson(Object? json) =>
      _decode(kind, () => DecisionRecord.fromJson(_object(json, kind)));
}

/// Stores a session's recap, replacing the one it had.
final class RecapWrite extends DataRequest<SessionRecap> {
  const RecapWrite(this.recap);

  static const String name = 'sessions.writeRecap';

  final SessionRecap recap;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'recap': recap.toJson()};

  @override
  Object? resultToJson(SessionRecap result) => result.toJson();

  @override
  SessionRecap resultFromJson(Object? json) =>
      _decode(kind, () => SessionRecap.fromJson(_object(json, kind)));
}

/// Drops a session's recap — the person dismissed it.
final class RecapDismiss extends _AckRequest {
  const RecapDismiss(this.sessionId);

  static const String name = 'sessions.dismissRecap';

  final String sessionId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'sessionId': sessionId};
}

/// Records a message one session sent another.
final class RelayRecord extends _AckRequest {
  const RelayRecord(this.relay);

  static const String name = 'sessions.recordRelay';

  final SessionRelay relay;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'relay': relay.toJson()};
}

/// The most recent [limit] relays into [toSessionId], oldest first, and how
/// many there are in all.
final class RelaysTo extends DataRequest<RelayPage> {
  const RelaysTo(this.toSessionId, this.limit);

  static const String name = 'sessions.relays';

  final String toSessionId;
  final int limit;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'to': toSessionId,
    'limit': limit,
  };

  @override
  Object? resultToJson(RelayPage result) => result.toJson();

  @override
  RelayPage resultFromJson(Object? json) =>
      _decode(kind, () => RelayPage.fromJson(_object(json, kind)));
}

/// How many times [fromSessionId] has sent to [toSessionId] since [since].
final class RelayCount extends DataRequest<int> {
  const RelayCount({
    required this.fromSessionId,
    required this.toSessionId,
    required this.since,
  });

  static const String name = 'sessions.relayCount';

  final String fromSessionId;
  final String toSessionId;
  final DateTime since;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'from': fromSessionId,
    'to': toSessionId,
    'since': since.toUtc().toIso8601String(),
  };

  @override
  Object? resultToJson(int result) => result;

  @override
  int resultFromJson(Object? json) => json is int ? json : _badAnswer(kind);
}

/// Raises a follow-up at the server's clock — or answers null when that
/// session already has one open: replacing it would reset the age the person
/// reads the list by.
final class FollowUpRaise extends DataRequest<FollowUp?> {
  const FollowUpRaise(this.followUp);

  static const String name = 'followUps.raise';

  final FollowUp followUp;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'followUp': followUp.toJson()};

  @override
  Object? resultToJson(FollowUp? result) => result?.toJson();

  @override
  FollowUp? resultFromJson(Object? json) => json == null
      ? null
      : _decode(kind, () => FollowUp.fromJson(_object(json, kind)));
}

/// Closes an open follow-up at the server's clock, recording which way it
/// went; answers it as it now stands. A no-op on one already closed.
final class FollowUpResolve extends DataRequest<FollowUp?> {
  const FollowUpResolve(this.id, this.resolution);

  static const String name = 'followUps.resolve';

  final int id;
  final FollowUpResolution resolution;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'id': id,
    'resolution': resolution.name,
  };

  @override
  Object? resultToJson(FollowUp? result) => result?.toJson();

  @override
  FollowUp? resultFromJson(Object? json) => json == null
      ? null
      : _decode(kind, () => FollowUp.fromJson(_object(json, kind)));
}

/// Imports a CLI conversation as history — unless that CLI's conversation is
/// already imported, or a session row already represents it. Answers
/// whether a record was written.
final class ImportedAdd extends DataRequest<bool> {
  const ImportedAdd(this.session);

  static const String name = 'imported.add';

  final ImportedSession session;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'session': importedToJson(session),
  };

  @override
  Object? resultToJson(bool result) => result;

  @override
  bool resultFromJson(Object? json) => json is bool ? json : _badAnswer(kind);
}

/// Renames an imported record.
final class ImportedRename extends _AckRequest {
  const ImportedRename({required this.id, required this.title});

  static const String name = 'imported.rename';

  final String id;
  final String title;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id, 'title': title};
}

/// Takes an imported record out of the workspace; the CLI's store is left.
final class ImportedDelete extends _AckRequest {
  const ImportedDelete(this.id);

  static const String name = 'imported.delete';

  final String id;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id};
}

/// A request answered with the session row it wrote.
sealed class _SessionWrite extends DataRequest<Session> {
  const _SessionWrite();

  @override
  Object? resultToJson(Session result) => result.toJson();

  @override
  Session resultFromJson(Object? json) =>
      _decode(kind, () => Session.fromJson(_object(json, kind)));
}

/// A request answered with a session's checkouts, the primary first.
sealed class _LinksRequest extends DataRequest<List<SessionRepositoryLink>> {
  const _LinksRequest();

  @override
  Object? resultToJson(List<SessionRepositoryLink> result) => [
    for (final link in result) link.toJson(),
  ];

  @override
  List<SessionRepositoryLink> resultFromJson(Object? json) => _decode(kind, () {
    return [
      for (final item in _objects(json, kind))
        SessionRepositoryLink.fromJson(item),
    ];
  });
}
