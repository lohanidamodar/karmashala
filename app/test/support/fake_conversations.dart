part of 'fake_data_server.dart';

/// The conversation index of a [FakeDataServer]: turns a test seeds, found by
/// plain words — every word of the query in one turn, the last as a prefix.
/// The server's ranking, cascade, excerpts and cursors are tested in
/// `packages/karmashala_conversations` and `server/test/data`, not here: this
/// answers the requests so the app's surfaces can be driven.
class FakeConversations {
  FakeConversations._();

  final _turns =
      <
        ({
          String conversationId,
          String cli,
          ConversationTurn turn,
          DateTime? indexedAt,
        })
      >[];

  /// Every search asked, in order.
  final searches = <ConversationsSearch>[];

  /// Catch-ups asked, and what the next one answers (conversations changed).
  var catchUps = 0;
  var catchUpChanges = 0;

  /// Runs as a catch-up is answered — a transcript that grew meanwhile.
  void Function()? onCatchUp;

  /// When set, every search is refused with it — a cursor the index moved
  /// past, say.
  DataRefused? refuseSearches;

  /// What `conversations.status` reports of its coverage; null reports none,
  /// as a server from before it was counted.
  ({int named, int unindexed, int unreadable, bool backfilling})? coverage;

  var _generation = 0;

  /// Indexes [turns] of [conversationId], as a read of its transcript would.
  void add(
    String conversationId,
    List<ConversationTurn> turns, {
    String cli = 'claudeCode',
    DateTime? indexedAt,
  }) {
    _generation++;
    for (final turn in turns) {
      _turns.add((
        conversationId: conversationId,
        cli: cli,
        turn: turn,
        indexedAt: indexedAt,
      ));
    }
  }

  /// One turn, the common case.
  void say(
    String conversationId,
    String text, {
    String cli = 'claudeCode',
    String role = 'user',
    int ordinal = 0,
    DateTime? at,
    DateTime? indexedAt,
  }) => add(
    conversationId,
    [ConversationTurn(ordinal: ordinal, role: role, text: text, at: at)],
    cli: cli,
    indexedAt: indexedAt,
  );

  Object? _handle(ConversationsRequest<Object?> request) => switch (request) {
    final ConversationsSearch r => _search(r),
    ConversationsCatchUp() => () {
      catchUps++;
      onCatchUp?.call();
      return catchUpChanges;
    }(),
    ConversationsTurns(:final conversationId, :final from, :final limit) => [
      for (final row in _turns)
        if (row.conversationId == conversationId && row.turn.ordinal >= from)
          row.turn,
    ].take(limit).toList(),
    ConversationsStatus() => ConversationIndexStatus(
      conversations: {for (final row in _turns) row.conversationId}.length,
      turns: _turns.length,
      generation: _generation,
      named: coverage?.named,
      unindexed: coverage?.unindexed,
      unreadable: coverage?.unreadable,
      backfilling: coverage?.backfilling ?? false,
    ),
  };

  SessionSearchPage _search(ConversationsSearch request) {
    searches.add(request);
    if (refuseSearches case final refused?) throw refused;
    final words = [
      for (final m in RegExp(
        r'[\p{L}\p{N}]+',
        unicode: true,
      ).allMatches(request.query.toLowerCase()))
        m[0]!,
    ];
    if (words.isEmpty) return SessionSearchPage.empty;
    bool says(String text) {
      final said = [
        for (final m in RegExp(
          r'[\p{L}\p{N}]+',
          unicode: true,
        ).allMatches(text.toLowerCase()))
          m[0]!,
      ];
      for (var i = 0; i < words.length; i++) {
        final last = i == words.length - 1;
        if (!said.any((w) => last ? w.startsWith(words[i]) : w == words[i])) {
          return false;
        }
      }
      return true;
    }

    final filter = request.filter;
    final best = <String, ConversationHit>{};
    for (final row in _turns) {
      if (filter.conversationId != null &&
          row.conversationId != filter.conversationId) {
        continue;
      }
      if (filter.cli != null && row.cli != filter.cli) continue;
      if (!says(row.turn.text)) continue;
      final seen = best[row.conversationId];
      best[row.conversationId] = ConversationHit(
        sessionId: row.conversationId,
        cli: row.cli,
        ordinal: seen?.ordinal ?? row.turn.ordinal,
        role: seen?.role ?? row.turn.role,
        excerpt: seen?.excerpt ?? row.turn.text,
        at: seen?.at ?? row.turn.at,
        indexedAt: row.indexedAt,
        matches: (seen?.matches ?? 0) + 1,
        tier: ConversationMatchTier.allWords,
      );
    }
    return SessionSearchPage(
      hits: best.values.take(request.limit).toList(),
      generation: _generation,
    );
  }
}
