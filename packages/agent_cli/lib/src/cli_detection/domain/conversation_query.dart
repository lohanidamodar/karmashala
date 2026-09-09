/// Characters a token must contain at least one of to be worth searching for.
///
/// FTS5's `unicode61` tokenizer throws punctuation away, so a token made only
/// of it — `...`, `->`, a lone `"` — becomes an empty phrase, and an empty
/// phrase is an FTS5 *syntax error* rather than a query that matches nothing.
final RegExp _searchable = RegExp(r'[\p{L}\p{N}]', unicode: true);

/// The shortest query worth running. One character prefix-matches most of the
/// store, so it is not a search, and this runs on every keystroke.
const int kConversationQueryMinimum = 2;

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
  final trimmed = query.trim();
  if (trimmed.length < kConversationQueryMinimum) return null;
  final tokens = [
    for (final token in trimmed.split(RegExp(r'\s+')))
      if (_searchable.hasMatch(token)) token,
  ];
  if (tokens.isEmpty) return null;
  final phrases = <String>[];
  for (var i = 0; i < tokens.length; i++) {
    // A doubled quote is how FTS5 writes one inside a string literal.
    final escaped = tokens[i].replaceAll('"', '""');
    phrases.add(i == tokens.length - 1 ? '"$escaped"*' : '"$escaped"');
  }
  return phrases.join(' ');
}
