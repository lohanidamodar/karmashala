/// Characters a token must contain at least one of to be worth searching for.
///
/// FTS5's `unicode61` tokenizer throws punctuation away, so a token made only
/// of it — `...`, `->`, a lone `"` — becomes an empty phrase, and an empty
/// phrase is an FTS5 *syntax error* rather than a query that matches nothing.
final RegExp _searchable = RegExp(r'[\p{L}\p{N}]', unicode: true);

/// The shortest query worth running. One character prefix-matches most of the
/// store, so it is not a search, and this runs on every keystroke.
const int kConversationQueryMinimum = 2;

/// The searchable tokens of what the user typed, or `null` when there is
/// nothing to search for.
List<String>? conversationQueryTokens(String query) {
  final trimmed = query.trim();
  if (trimmed.length < kConversationQueryMinimum) return null;
  final tokens = [
    for (final token in trimmed.split(RegExp(r'\s+')))
      if (_searchable.hasMatch(token)) token,
  ];
  return tokens.isEmpty ? null : tokens;
}

/// A doubled quote is how FTS5 writes one inside a string literal.
String _literal(String token) => '"${token.replaceAll('"', '""')}"';

/// The FTS5 `MATCH` expression for what the user typed, or `null` when there is
/// nothing to search for.
///
/// **Every token is wrapped as an FTS5 string literal**, so nothing typed can
/// be read as an operator: `AND`, `OR`, `NOT`, `NEAR`, `(`, `-`, `^`, `:` and a
/// stray `"` are all just characters. Refusing query syntax is the point — a
/// palette that answered `fts5: syntax error near "("` to a half-finished query
/// would be worse than one that cannot express a boolean, and there is no
/// escaping scheme that makes user input safe as an operator expression.
///
/// Tokens are implicitly ANDed, and the **last one is a prefix**: this runs
/// while the user is still typing, so `worktre` has to be already finding
/// `worktree`.
String? conversationMatchExpression(String query) {
  final tokens = conversationQueryTokens(query);
  return tokens == null ? null : conversationAllWordsExpression(tokens);
}

/// Every token, ANDed, the last a prefix.
String conversationAllWordsExpression(List<String> tokens) => [
  for (var i = 0; i < tokens.length; i++)
    i == tokens.length - 1 ? '${_literal(tokens[i])}*' : _literal(tokens[i]),
].join(' ');

/// The tokens as one phrase, in order, the last a prefix. Null for one token,
/// where it would be the all-words expression again.
String? conversationPhraseExpression(List<String> tokens) =>
    tokens.length < 2 ? null : '${_literal(tokens.join(' '))}*';

/// Any one of the tokens, the last a prefix. Null for one token.
String? conversationAnyWordExpression(List<String> tokens) {
  if (tokens.length < 2) return null;
  return [
    for (var i = 0; i < tokens.length; i++)
      i == tokens.length - 1 ? '${_literal(tokens[i])}*' : _literal(tokens[i]),
  ].join(' OR ');
}

/// How strictly a result matched, strictest first. A search runs the tiers in
/// this order and stops once it has enough, so a query degrades rather than
/// answering nothing.
enum ConversationMatchTier {
  /// The words, adjacent and in order.
  phrase,

  /// Every word, anywhere in the turn.
  allWords,

  /// Every word, after a word the index has never seen was swapped for the
  /// nearest one it has.
  repaired,

  /// Any one of the words.
  anyWord,
}

/// The expressions a search runs, in order, for [query]. [repairs] maps a
/// token the index has never seen to the term it should be read as.
List<({ConversationMatchTier tier, String expression})>
conversationMatchCascade(
  String query, {
  Map<String, String> repairs = const {},
}) {
  final tokens = conversationQueryTokens(query);
  if (tokens == null) return const [];
  final out = <({ConversationMatchTier tier, String expression})>[];
  final seen = <String>{};
  void add(ConversationMatchTier tier, String? expression) {
    if (expression != null && seen.add(expression)) {
      out.add((tier: tier, expression: expression));
    }
  }

  add(ConversationMatchTier.phrase, conversationPhraseExpression(tokens));
  add(ConversationMatchTier.allWords, conversationAllWordsExpression(tokens));
  final repaired = [for (final token in tokens) repairs[token] ?? token];
  if (repairs.isNotEmpty) {
    add(
      ConversationMatchTier.repaired,
      conversationAllWordsExpression(repaired),
    );
  }
  add(
    ConversationMatchTier.anyWord,
    conversationAnyWordExpression({...tokens, ...repaired}.toList()),
  );
  return out;
}
