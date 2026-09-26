import 'dart:convert';

import 'package:agent_cli/read.dart' show ConversationMatchTier;
import 'package:karmashala_conversations/karmashala_conversations.dart';
import 'package:test/test.dart';

/// Every value a client is answered with survives the wire: through
/// `jsonEncode`, as the envelope carries it, and back.
Map<String, Object?> _wire(Map<String, Object?> json) =>
    (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

void main() {
  final at = DateTime.utc(2026, 9, 27, 10, 30);

  test('a hit, with its tier and both times', () {
    final hit = ConversationHit(
      sessionId: 'c1',
      cli: 'claudeCode',
      ordinal: 4,
      role: 'agent',
      excerpt: '…the webhook retries…',
      indexedAt: at,
      at: at.subtract(const Duration(hours: 1)),
      matches: 3,
      tier: ConversationMatchTier.repaired,
    );

    final back = ConversationHit.fromJson(_wire(hit.toJson()));
    expect(back.sessionId, 'c1');
    expect(back.cli, 'claudeCode');
    expect(back.ordinal, 4);
    expect(back.role, 'agent');
    expect(back.excerpt, '…the webhook retries…');
    expect(back.indexedAt, at);
    expect(back.at, at.subtract(const Duration(hours: 1)));
    expect(back.matches, 3);
    expect(back.tier, ConversationMatchTier.repaired);
  });

  test('a hit with no tier and no times', () {
    const hit = ConversationHit(
      sessionId: 'c1',
      cli: 'codex',
      ordinal: 0,
      role: 'user',
      excerpt: 'x',
    );
    final back = ConversationHit.fromJson(_wire(hit.toJson()));
    expect(back.tier, isNull);
    expect(back.at, isNull);
    expect(back.indexedAt, isNull);
    expect(back.matches, 1);
  });

  test('an unknown tier is a format error, not a guess', () {
    final json = const ConversationHit(
      sessionId: 'c1',
      cli: 'codex',
      ordinal: 0,
      role: 'user',
      excerpt: 'x',
    ).toJson()..['tier'] = 'psychic';
    expect(() => ConversationHit.fromJson(json), throwsFormatException);
  });

  test('a filter, every field and none', () {
    final filter = SessionSearchFilter(
      conversationId: 'c1',
      cli: 'codex',
      projectId: 'p1',
      repositoryId: 'r1',
      after: at,
      before: at.add(const Duration(days: 1)),
    );
    final back = SessionSearchFilter.fromJson(_wire(filter.toJson()));
    expect(back.fingerprint, filter.fingerprint);
    expect(back.after, at);
    expect(back.isEmpty, isFalse);

    const empty = SessionSearchFilter();
    expect(empty.toJson(), isEmpty, reason: 'nothing said is nothing sent');
    expect(SessionSearchFilter.fromJson(const {}).isEmpty, isTrue);
  });

  test('a page, with its cursor and generation', () {
    final page = SessionSearchPage(
      hits: [
        const ConversationHit(
          sessionId: 'c1',
          cli: 'claudeCode',
          ordinal: 1,
          role: 'user',
          excerpt: 'a',
        ),
        ConversationHit(
          sessionId: 'c2',
          cli: 'codex',
          ordinal: 2,
          role: 'agent',
          excerpt: 'b',
          tier: ConversationMatchTier.phrase,
          indexedAt: at,
        ),
      ],
      generation: 7,
      nextCursor: 'abc',
    );
    final back = SessionSearchPage.fromJson(_wire(page.toJson()));
    expect(back.hits.map((h) => h.sessionId), ['c1', 'c2']);
    expect(back.hits.last.tier, ConversationMatchTier.phrase);
    expect(back.generation, 7);
    expect(back.nextCursor, 'abc');

    final last = SessionSearchPage.fromJson(
      _wire(SessionSearchPage.empty.toJson()),
    );
    expect(last.hits, isEmpty);
    expect(last.nextCursor, isNull);
  });

  test('a turn', () {
    final turn = ConversationTurn(
      ordinal: 3,
      role: 'agent',
      text: 'done',
      at: at,
    );
    final back = ConversationTurn.fromJson(_wire(turn.toJson()));
    expect(
      [back.ordinal, back.role, back.text, back.at],
      [3, 'agent', 'done', at],
    );
    expect(
      ConversationTurn.fromJson(
        _wire(
          const ConversationTurn(ordinal: 0, role: 'user', text: 'x').toJson(),
        ),
      ).at,
      isNull,
    );
  });

  test('the index status', () {
    final status = ConversationIndexStatus(
      conversations: 12,
      turns: 340,
      generation: 9,
      backfilledAt: at,
      backfilling: true,
      queued: 2,
    );
    final back = ConversationIndexStatus.fromJson(_wire(status.toJson()));
    expect(back.conversations, 12);
    expect(back.turns, 340);
    expect(back.generation, 9);
    expect(back.backfilledAt, at);
    expect(back.backfilling, isTrue);
    expect(back.queued, 2);

    final fresh = ConversationIndexStatus.fromJson(
      _wire(
        const ConversationIndexStatus(
          conversations: 0,
          turns: 0,
          generation: 0,
        ).toJson(),
      ),
    );
    expect(fresh.backfilledAt, isNull);
    expect(fresh.backfilling, isFalse);
  });
}
