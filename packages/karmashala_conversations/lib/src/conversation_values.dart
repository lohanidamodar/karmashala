import 'package:agent_cli/read.dart' show ConversationMatchTier;

/// One visible turn, as the index holds it: on its way in, and as
/// `conversations.turns` answers it.
class ConversationTurn {
  const ConversationTurn({
    required this.ordinal,
    required this.role,
    required this.text,
    this.at,
  });

  /// The turn's position in the transcript as parsed, tool rows included. A
  /// hint, never a key: format drift shifts every ordinal after it.
  final int ordinal;

  /// `user` or `agent`. A `tool` row never reaches here — see
  /// `ConversationIndexer`.
  final String role;

  final String text;

  /// When the CLI wrote it, off the line's own timestamp. Null when the line
  /// carried none, and for rows indexed before v56.
  final DateTime? at;

  Map<String, Object?> toJson() => {
    'ordinal': ordinal,
    'role': role,
    'text': text,
    'at': _iso(at),
  };

  static ConversationTurn fromJson(Map<String, Object?> json) =>
      ConversationTurn(
        ordinal: json['ordinal'] as int,
        role: json['role'] as String,
        text: json['text'] as String,
        at: _date(json['at']),
      );
}

/// One matching turn, with the conversation it was said in.
class ConversationHit {
  const ConversationHit({
    required this.sessionId,
    required this.cli,
    required this.ordinal,
    required this.role,
    required this.excerpt,
    this.indexedAt,
    this.at,
    this.matches = 1,
    this.tier,
    this.rowId,
  });

  /// The agent's own conversation id.
  final String sessionId;
  final String cli;
  final int ordinal;
  final String role;

  /// The matched text, cut down to the words around the match.
  final String excerpt;

  /// When this conversation was last read off disk — the age of the reading,
  /// which the surface showing a hit has to be able to say (CLAUDE.md §19).
  final DateTime? indexedAt;

  /// When the matching turn was said, where the transcript recorded it.
  final DateTime? at;

  /// Turns in this conversation that matched, the one shown included.
  final int matches;

  /// How strictly it matched. Null from `ConversationIndexDao.search`, which
  /// runs one expression.
  final ConversationMatchTier? tier;

  /// The session that holds this conversation as an earlier agent's part of
  /// a switched thread, which no row names by this id any more; null when a
  /// row names it.
  final String? rowId;

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'cli': cli,
    'ordinal': ordinal,
    'role': role,
    'excerpt': excerpt,
    'indexedAt': _iso(indexedAt),
    'at': _iso(at),
    'matches': matches,
    'tier': tier?.name,
    'rowId': ?rowId,
  };

  static ConversationHit fromJson(Map<String, Object?> json) => ConversationHit(
    sessionId: json['sessionId'] as String,
    cli: json['cli'] as String,
    ordinal: json['ordinal'] as int,
    role: json['role'] as String,
    excerpt: json['excerpt'] as String,
    indexedAt: _date(json['indexedAt']),
    at: _date(json['at']),
    matches: json['matches'] as int? ?? 1,
    rowId: json['rowId'] as String?,
    tier: switch (json['tier']) {
      final String name => ConversationMatchTier.values.firstWhere(
        (tier) => tier.name == name,
        orElse: () => throw FormatException('no match tier "$name"'),
      ),
      _ => null,
    },
  );
}

/// What a search may be narrowed to. Every field is optional and they AND.
/// Structured on purpose: parsing `repo:` or `before:` out of typed text is
/// the command palette's job, not the index's.
class SessionSearchFilter {
  const SessionSearchFilter({
    this.conversationId,
    this.cli,
    this.projectId,
    this.repositoryId,
    this.after,
    this.before,
  });

  /// One conversation — the CLI's own id — rather than all of them.
  final String? conversationId;

  /// One agent, by id (`claudeCode`, `codex`, …).
  final String? cli;

  /// Conversations a session or imported record files under this project or
  /// repository.
  final String? projectId;
  final String? repositoryId;

  /// Turns said at or after [after] and before [before]. A turn with no
  /// recorded time never passes a date bound: unknown is not in range.
  final DateTime? after;
  final DateTime? before;

  bool get isEmpty =>
      conversationId == null &&
      cli == null &&
      projectId == null &&
      repositoryId == null &&
      after == null &&
      before == null;

  /// A stable spelling, for telling one search's cursor from another's.
  String get fingerprint => [
    conversationId,
    cli,
    projectId,
    repositoryId,
    _iso(after),
    _iso(before),
  ].map((v) => v ?? '').join('|');

  Map<String, Object?> toJson() => {
    'conversationId': ?conversationId,
    'cli': ?cli,
    'projectId': ?projectId,
    'repositoryId': ?repositoryId,
    'after': ?_iso(after),
    'before': ?_iso(before),
  };

  static SessionSearchFilter fromJson(Map<String, Object?> json) =>
      SessionSearchFilter(
        conversationId: json['conversationId'] as String?,
        cli: json['cli'] as String?,
        projectId: json['projectId'] as String?,
        repositoryId: json['repositoryId'] as String?,
        after: _date(json['after']),
        before: _date(json['before']),
      );
}

/// One page of a session search: a conversation per hit, best first.
class SessionSearchPage {
  const SessionSearchPage({
    required this.hits,
    required this.generation,
    this.nextCursor,
  });

  static const SessionSearchPage empty = SessionSearchPage(
    hits: [],
    generation: 0,
  );

  final List<ConversationHit> hits;

  /// Pass back to read the page after this one. Null on the last page.
  final String? nextCursor;

  /// The index generation this page was cut at.
  final int generation;

  Map<String, Object?> toJson() => {
    'hits': [for (final hit in hits) hit.toJson()],
    'generation': generation,
    'nextCursor': nextCursor,
  };

  static SessionSearchPage fromJson(Map<String, Object?> json) =>
      SessionSearchPage(
        hits: [
          for (final hit in json['hits'] as List)
            ConversationHit.fromJson((hit as Map).cast<String, Object?>()),
        ],
        generation: json['generation'] as int,
        nextCursor: json['nextCursor'] as String?,
      );
}

/// Where the index stands: what `conversations.status` answers.
class ConversationIndexStatus {
  const ConversationIndexStatus({
    required this.conversations,
    required this.turns,
    required this.generation,
    this.backfilledAt,
    this.backfilling = false,
    this.queued = 0,
    this.named,
    this.unindexed,
    this.unreadable,
  });

  /// Conversations a session or imported record names: what a search could
  /// cover. Null from a server that does not count them.
  final int? named;

  /// Of [named], the ones the index holds no reading of: their agent's store
  /// did not have them, or has not been asked yet. Null: not counted.
  final int? unindexed;

  /// Conversations whose last read failed since the server started — their
  /// store unreachable or their transcript unopenable — so what the index
  /// holds of them may be old. Null: not counted.
  final int? unreadable;

  /// Conversations the index has read at least once, and the turns it holds.
  final int conversations;
  final int turns;

  /// Bumped by every write that changes what a search can find.
  final int generation;

  /// When the one-off catch-up over the workspace's history finished; null
  /// until it has.
  final DateTime? backfilledAt;

  /// Whether that catch-up is running now.
  final bool backfilling;

  /// Conversations waiting to be read.
  final int queued;

  Map<String, Object?> toJson() => {
    'conversations': conversations,
    'turns': turns,
    'generation': generation,
    'backfilledAt': _iso(backfilledAt),
    'backfilling': backfilling,
    'queued': queued,
    if (named != null) 'named': named,
    if (unindexed != null) 'unindexed': unindexed,
    if (unreadable != null) 'unreadable': unreadable,
  };

  static ConversationIndexStatus fromJson(Map<String, Object?> json) =>
      ConversationIndexStatus(
        conversations: json['conversations'] as int,
        turns: json['turns'] as int,
        generation: json['generation'] as int,
        backfilledAt: _date(json['backfilledAt']),
        backfilling: json['backfilling'] as bool? ?? false,
        queued: json['queued'] as int? ?? 0,
        named: json['named'] as int?,
        unindexed: json['unindexed'] as int?,
        unreadable: json['unreadable'] as int?,
      );
}

/// The `app_metadata` key counting writes to the index. A cursor carries the
/// value it was cut at, so a write in between rejects the page it would tear.
const String kConversationIndexGenerationKey = 'conversation_index_generation';

/// The `app_metadata` key stamped once the index has caught up with what the
/// workspace already had, which makes the backfill a one-off, not a sweep.
const String kConversationIndexBackfilledAtKey =
    'conversation_index_backfilled_at';

String? _iso(DateTime? value) => value?.toUtc().toIso8601String();

DateTime? _date(Object? value) => switch (value) {
  final String text => DateTime.parse(text).toUtc(),
  null => null,
  _ => throw FormatException('not a time: $value'),
};
