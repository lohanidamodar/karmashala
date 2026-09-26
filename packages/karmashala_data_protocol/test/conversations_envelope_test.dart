import 'dart:convert';

import 'package:agent_cli/read.dart' show ConversationMatchTier;
import 'package:karmashala_conversations/karmashala_conversations.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:test/test.dart';

/// The conversation index's requests (slice 1f) through the envelope as JSON.
void main() {
  final t0 = DateTime.utc(2026, 9, 27, 9, 30);

  Map<String, Object?> overTheWire(Map<String, Object?> json) =>
      (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

  DataRequest<Object?>? read(Map<String, Object?> json) =>
      DataEnvelope.readRequest(overTheWire(json)).request;

  DataReply<R> roundTrip<R>(DataRequest<R> request, R result) =>
      DataEnvelope.readAnswer(
        overTheWire(
          DataEnvelope.answer(4, request, DataReply(result, 9, const [])),
        ),
        request,
      );

  test('every request round-trips with its arguments', () {
    final requests = <DataRequest<Object?>>[
      const ConversationsSearch('rate limit'),
      ConversationsSearch(
        'heap',
        filter: SessionSearchFilter(
          conversationId: 'c1',
          cli: 'codex',
          projectId: 'p1',
          repositoryId: 'r1',
          after: t0,
          before: t0.add(const Duration(days: 1)),
        ),
        limit: 5,
        cursor: 'abc',
      ),
      const ConversationsCatchUp(),
      const ConversationsTurns('c1', from: 3, limit: 7),
      const ConversationsStatus(),
    ];
    for (final request in requests) {
      final back = read(DataEnvelope.request(3, request));
      expect(back, isNotNull, reason: request.kind);
      expect(back!.kind, request.kind);
      expect(
        back.argumentsToJson(),
        overTheWire(request.argumentsToJson()),
        reason: request.kind,
      );
    }
  });

  test('a search reads its defaults and its filter back', () {
    final bare =
        read({
              'id': 1,
              'kind': 'conversations.search',
              'arguments': {'query': 'x'},
            })!
            as ConversationsSearch;
    expect(bare.limit, 20);
    expect(bare.cursor, isNull);
    expect(bare.filter.isEmpty, isTrue);

    final filtered =
        read(
              DataEnvelope.request(
                2,
                ConversationsSearch(
                  'x',
                  filter: SessionSearchFilter(cli: 'claudeCode', after: t0),
                ),
              ),
            )!
            as ConversationsSearch;
    expect(filtered.filter.cli, 'claudeCode');
    expect(filtered.filter.after, t0);
    expect(filtered.filter.fingerprint, contains('claudeCode'));

    final turns =
        read({
              'id': 1,
              'kind': 'conversations.turns',
              'arguments': {'conversationId': 'c'},
            })!
            as ConversationsTurns;
    expect((turns.from, turns.limit), (0, 200));
  });

  test('a filter, query or conversation out of shape is refused invalid', () {
    for (final json in [
      {
        'id': 1,
        'kind': 'conversations.search',
        'arguments': {'query': 'x', 'filter': 'everything'},
      },
      {
        'id': 1,
        'kind': 'conversations.search',
        'arguments': {
          'query': 'x',
          'filter': {'after': 'not a time'},
        },
      },
      {
        'id': 1,
        'kind': 'conversations.search',
        'arguments': {'query': 3},
      },
      {
        'id': 1,
        'kind': 'conversations.turns',
        'arguments': {'conversationId': 'c', 'limit': 'many'},
      },
      {'id': 1, 'kind': 'conversations.nope', 'arguments': {}},
    ]) {
      final result = DataEnvelope.readRequest(overTheWire(json));
      expect(result.refusal?.code, DataRefusalCode.invalid, reason: '$json');
    }
  });

  test('answers carry typed results', () {
    final hit = ConversationHit(
      sessionId: 'c1',
      cli: 'claudeCode',
      ordinal: 4,
      role: 'user',
      excerpt: '…the rate limiter…',
      indexedAt: t0,
      at: t0.subtract(const Duration(hours: 1)),
      matches: 3,
      tier: ConversationMatchTier.phrase,
    );
    final page = roundTrip(
      const ConversationsSearch('rate'),
      SessionSearchPage(
        hits: [
          hit,
          const ConversationHit(
            sessionId: 'c2',
            cli: 'codex',
            ordinal: 0,
            role: 'agent',
            excerpt: 'rate',
          ),
        ],
        generation: 12,
        nextCursor: 'next',
      ),
    ).value;
    expect(page.generation, 12);
    expect(page.nextCursor, 'next');
    expect(page.hits.first.toJson(), overTheWire(hit.toJson()));
    expect(page.hits.first.tier, ConversationMatchTier.phrase);
    expect(page.hits.last.tier, isNull);
    expect(page.hits.last.indexedAt, isNull);
    expect(page.hits.last.matches, 1);

    expect(roundTrip(const ConversationsCatchUp(), 3).value, 3);

    final turns = roundTrip(const ConversationsTurns('c1'), [
      ConversationTurn(ordinal: 0, role: 'user', text: 'hi', at: t0),
      const ConversationTurn(ordinal: 1, role: 'agent', text: 'hello'),
    ]).value;
    expect(
      [for (final t in turns) (t.ordinal, t.role, t.text, t.at)],
      [(0, 'user', 'hi', t0), (1, 'agent', 'hello', null)],
    );

    final status = roundTrip(
      const ConversationsStatus(),
      ConversationIndexStatus(
        conversations: 2,
        turns: 9,
        generation: 4,
        backfilledAt: t0,
        backfilling: true,
        queued: 1,
      ),
    ).value;
    expect(status.toJson(), overTheWire(status.toJson()));
    expect((status.conversations, status.turns, status.generation), (2, 9, 4));
    expect(status.backfilledAt, t0);
    expect(status.backfilling, isTrue);
    expect(status.queued, 1);
  });

  test('an answer this client cannot read is refused failed', () {
    Matcher failed() => throwsA(
      isA<DataRefused>().having((r) => r.code, 'code', DataRefusalCode.failed),
    );
    Map<String, Object?> answer(Object? result) => {
      'id': 1,
      'revision': 1,
      'result': result,
    };
    expect(
      () => DataEnvelope.readAnswer(
        answer('nope'),
        const ConversationsSearch('x'),
      ),
      failed(),
    );
    expect(
      () => DataEnvelope.readAnswer(
        answer({
          'hits': [
            {
              'sessionId': 'c',
              'cli': 'x',
              'ordinal': 0,
              'role': 'user',
              'excerpt': 'e',
              'tier': 'sideways',
            },
          ],
          'generation': 1,
        }),
        const ConversationsSearch('x'),
      ),
      failed(),
    );
    expect(
      () => DataEnvelope.readAnswer(answer('3'), const ConversationsCatchUp()),
      failed(),
    );
    expect(
      () => DataEnvelope.readAnswer(
        answer({'turns': 1}),
        const ConversationsTurns('c'),
      ),
      failed(),
    );
    expect(
      () => DataEnvelope.readAnswer(answer([]), const ConversationsStatus()),
      failed(),
    );
  });

  test('the index\'s own keys are not preferences', () {
    expect(PreferenceKeys.isReserved(kConversationIndexGenerationKey), isTrue);
    expect(
      PreferenceKeys.isReserved(kConversationIndexBackfilledAtKey),
      isTrue,
    );
  });
}
