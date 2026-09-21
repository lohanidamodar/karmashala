import 'package:test/test.dart';
import 'package:agent_cli/src/cli_detection/domain/conversation_query.dart';

void main() {
  test('one character is not a search', () {
    expect(conversationMatchExpression('w'), isNull);
    expect(conversationMatchExpression('  '), isNull);
  });

  test('the last token is a prefix, so it matches while still being typed', () {
    expect(conversationMatchExpression('worktre'), '"worktre"*');
  });

  test('two tokens are ANDed, and only the last one is a prefix', () {
    expect(
      conversationMatchExpression('decide caching'),
      '"decide" "caching"*',
    );
  });

  test('an operator the user typed is a word, not an operator', () {
    // FTS5 would read every one of these as syntax. A palette that answered a
    // syntax error to a half-finished query would be worse than one that
    // cannot express a boolean.
    expect(
      conversationMatchExpression('cache OR heap'),
      '"cache" "OR" "heap"*',
    );
    expect(conversationMatchExpression('NEAR(a b)'), '"NEAR(a" "b)"*');
    expect(conversationMatchExpression('-flag'), '"-flag"*');
  });

  test('a quote is doubled rather than escaping the literal', () {
    expect(conversationMatchExpression('say "no"'), '"say" """no"""*');
  });

  test('a token with nothing tokenisable in it is dropped', () {
    // `unicode61` throws punctuation away, so `...` would become an empty
    // phrase — an FTS5 syntax error, not a query that matches nothing.
    expect(conversationMatchExpression('...'), isNull);
    expect(conversationMatchExpression('-> heap'), '"heap"*');
  });

  test('non-latin text is searchable', () {
    expect(conversationMatchExpression('निर्णय'), '"निर्णय"*');
  });

  group('the cascade', () {
    test('several words: phrase, then all, then any', () {
      final steps = conversationMatchCascade('stripe webhook');
      expect(
        [for (final s in steps) s.tier],
        [
          ConversationMatchTier.phrase,
          ConversationMatchTier.allWords,
          ConversationMatchTier.anyWord,
        ],
      );
      expect(steps[0].expression, '"stripe webhook"*');
      expect(steps[1].expression, '"stripe" "webhook"*');
      expect(steps[2].expression, '"stripe" OR "webhook"*');
    });

    test('one word has no phrase and no any-word tier of its own', () {
      // Both would be the all-words expression again, run for nothing.
      final steps = conversationMatchCascade('webhook');
      expect([for (final s in steps) s.tier], [ConversationMatchTier.allWords]);
    });

    test('a repair adds a tier and widens the any-word one', () {
      final steps = conversationMatchCascade(
        'stirpe webhook',
        repairs: {'stirpe': 'stripe'},
      );
      expect(
        [for (final s in steps) s.tier],
        [
          ConversationMatchTier.phrase,
          ConversationMatchTier.allWords,
          ConversationMatchTier.repaired,
          ConversationMatchTier.anyWord,
        ],
      );
      expect(steps[2].expression, '"stripe" "webhook"*');
      expect(steps[3].expression, '"stirpe" OR "webhook" OR "stripe"*');
    });

    test('an operator is still a word in every tier', () {
      for (final step in conversationMatchCascade('NEAR( OR "x')) {
        // Nothing unquoted but the OR this function itself joins with.
        final outside = step.expression
            .replaceAll(RegExp(r'"(?:[^"]|"")*"\*?'), '')
            .replaceAll(' OR ', '')
            .trim();
        expect(outside, isEmpty, reason: step.expression);
      }
    });

    test('nothing to search for is no steps at all', () {
      expect(conversationMatchCascade('x'), isEmpty);
      expect(conversationMatchCascade('... ->'), isEmpty);
    });
  });
}
