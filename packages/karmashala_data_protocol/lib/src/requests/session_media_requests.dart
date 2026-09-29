part of '../data_request.dart';

// A session's pictures, extracted on the server where its record is (Stage 0
// step 10). The bytes are not carried here: a client brings each through
// `files.read`, as any file it opens. An older server refuses the kind as
// `invalid`; a client then scans its own disk, as before.

DataRequest<Object?>? _sessionMediaRequestFromJson(
  String kind,
  _Arguments args,
) => switch (kind) {
  SessionMediaRead.name => SessionMediaRead(
    args.string('sessionId'),
    known: args.optionalString('known'),
  ),
  _ => null,
};

/// Session [sessionId]'s pictures, newest first. [known] is the
/// [SessionMediaListing.stamp] last answered: when nothing changed since, the
/// answer is `unchanged` with no items.
final class SessionMediaRead
    extends SessionTranscriptRequest<SessionMediaListing> {
  const SessionMediaRead(this.sessionId, {this.known});

  static const String name = 'sessions.media';

  final String sessionId;

  final String? known;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'sessionId': sessionId,
    'known': ?known,
  };

  @override
  Object? resultToJson(SessionMediaListing result) => result.toJson();

  @override
  SessionMediaListing resultFromJson(Object? json) =>
      _decode(kind, () => SessionMediaListing.fromJson(_object(json, kind)));
}

/// What `sessions.media` answers. An item's `path` is on the server's
/// machine: the agent's own spelling when `SessionMediaItem.fromAgentEnvironment`
/// (in the session's environment), else a copy the server extracted, in its
/// host environment.
class SessionMediaListing {
  const SessionMediaListing({
    this.items = const [],
    this.stamp = '',
    this.unchanged = false,
    this.absence,
  });

  /// Newest first; empty when [unchanged].
  final List<SessionMediaItem> items;

  /// Names this reading of the record; asked back as `known`.
  final String stamp;

  /// Nothing changed since the `known` stamp; keep what is held.
  final bool unchanged;

  /// Why there is no record to read; null when one was.
  final ChatViewEvidence? absence;

  Map<String, Object?> toJson() => {
    'items': [for (final item in items) item.toJson()],
    'stamp': stamp,
    if (unchanged) 'unchanged': true,
    'absence': ?absence?.name,
  };

  static SessionMediaListing fromJson(Map<String, Object?> json) {
    final absence = json['absence'];
    return SessionMediaListing(
      items: [
        for (final item in (json['items'] as List?) ?? const [])
          ?SessionMediaItem.fromJson(item),
      ],
      stamp: json['stamp'] as String? ?? '',
      unchanged: json['unchanged'] == true,
      absence: absence is String
          ? ChatViewEvidence.values.asNameMap()[absence] ??
                ChatViewEvidence.notLocated
          : null,
    );
  }
}
