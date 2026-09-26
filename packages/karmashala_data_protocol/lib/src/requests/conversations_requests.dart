part of '../data_request.dart';

// The conversation index: full-text search over what was said in every
// conversation, kept by the server. Nothing here writes a row a client
// copies, so none of it is told as a change.

DataRequest<Object?>? _conversationsRequestFromJson(
  String kind,
  _Arguments args,
) => switch (kind) {
  ConversationsSearch.name => ConversationsSearch(
    args.string('query'),
    filter: args.values['filter'] == null
        ? const SessionSearchFilter()
        : args.value('filter', SessionSearchFilter.fromJson),
    limit: args.optionalInt('limit') ?? 20,
    cursor: args.optionalString('cursor'),
  ),
  ConversationsCatchUp.name => const ConversationsCatchUp(),
  ConversationsTurns.name => ConversationsTurns(
    args.string('conversationId'),
    from: args.optionalInt('from') ?? 0,
    limit: args.optionalInt('limit') ?? 200,
  ),
  ConversationsStatus.name => const ConversationsStatus(),
  _ => null,
};

/// A request of the conversation index.
sealed class ConversationsRequest<R> extends DataRequest<R> {
  const ConversationsRequest();
}

/// Conversations that said [query], best first, [limit] a page, narrowed by
/// [filter]; [cursor] is the last page's `nextCursor`. Refused `invalid` for
/// a cursor cut for another search, or one the index has moved past (search
/// again from the top).
final class ConversationsSearch
    extends ConversationsRequest<SessionSearchPage> {
  const ConversationsSearch(
    this.query, {
    this.filter = const SessionSearchFilter(),
    this.limit = 20,
    this.cursor,
  });

  static const String name = 'conversations.search';

  final String query;
  final SessionSearchFilter filter;
  final int limit;
  final String? cursor;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'query': query,
    if (!filter.isEmpty) 'filter': filter.toJson(),
    'limit': limit,
    'cursor': ?cursor,
  };

  @override
  Object? resultToJson(SessionSearchPage result) => result.toJson();

  @override
  SessionSearchPage resultFromJson(Object? json) =>
      _decode(kind, () => SessionSearchPage.fromJson(_object(json, kind)));
}

/// Reads what the running sessions' transcripts appended since they were last
/// indexed — at most once every few seconds, however often asked. Answered
/// when it is done, with how many conversations changed; a search after it
/// finds today's turns.
final class ConversationsCatchUp extends ConversationsRequest<int> {
  const ConversationsCatchUp();

  static const String name = 'conversations.catchUp';

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => const {};

  @override
  Object? resultToJson(int result) => result;

  @override
  int resultFromJson(Object? json) => json is int ? json : _badAnswer(kind);
}

/// One conversation's indexed turns, in the order said, from ordinal [from].
final class ConversationsTurns
    extends ConversationsRequest<List<ConversationTurn>> {
  const ConversationsTurns(
    this.conversationId, {
    this.from = 0,
    this.limit = 200,
  });

  static const String name = 'conversations.turns';

  final String conversationId;
  final int from;
  final int limit;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'conversationId': conversationId,
    'from': from,
    'limit': limit,
  };

  @override
  Object? resultToJson(List<ConversationTurn> result) => [
    for (final turn in result) turn.toJson(),
  ];

  @override
  List<ConversationTurn> resultFromJson(Object? json) => _decode(kind, () {
    return [
      for (final turn in _objects(json, kind)) ConversationTurn.fromJson(turn),
    ];
  });
}

/// Where the index stands: what it holds, and whether the one-off backfill
/// over the workspace's history has run.
final class ConversationsStatus
    extends ConversationsRequest<ConversationIndexStatus> {
  const ConversationsStatus();

  static const String name = 'conversations.status';

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => const {};

  @override
  Object? resultToJson(ConversationIndexStatus result) => result.toJson();

  @override
  ConversationIndexStatus resultFromJson(Object? json) => _decode(
    kind,
    () => ConversationIndexStatus.fromJson(_object(json, kind)),
  );
}
