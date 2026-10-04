import 'dart:convert';

import 'package:agent_cli/read.dart';
import 'package:karmashala_core/util.dart';

import 'conversation_index_dao.dart';
import 'conversation_values.dart';
import 'conversation_indexer.dart';

/// A cursor cut before the index changed. Serving it would skip or repeat
/// conversations, so the search has to be asked again from the top.
class StaleSearchCursor implements Exception {
  const StaleSearchCursor();

  @override
  String toString() =>
      'The conversation index changed since that page was served, so the '
      'next page would skip or repeat results. Search again without a cursor.';
}

/// The most conversations a search will page through. Past it a query is too
/// broad for paging to help, and every page would re-rank a growing prefix.
const int kSessionSearchDepth = 500;

/// Full-text search over every conversation's visible turns: the one callable
/// service behind quick open and the `session_search` tool.
///
/// A query runs as a cascade — the words as a phrase, then every word; only if
/// neither finds anything, every word with unknown ones repaired to the
/// nearest indexed term; and only if that finds nothing, any one word. So it
/// narrows when it can and degrades instead of answering nothing. Ranking
/// within a tier is FTS5's BM25, phrase hits before the rest.
class SessionSearchService {
  SessionSearchService({
    required this.dao,
    required this.clock,
    this.indexer,
    this.catchUpInterval = const Duration(seconds: 10),
  });

  final ConversationIndexDao dao;
  final Clock clock;

  /// What [catchUp] reads transcripts through; null makes it a no-op.
  final ConversationIndexer? indexer;

  /// The least time between two [catchUp]s that actually look at the disk.
  final Duration catchUpInterval;

  DateTime? _lastCatchUp;
  Future<int>? _catchingUp;

  /// Searches for [text] within [filter], [limit] conversations a page. Throws
  /// [StaleSearchCursor] for a [cursor] the index has moved past, and
  /// [ArgumentError] for one cut for a different search.
  SessionSearchPage search(
    String text, {
    SessionSearchFilter filter = const SessionSearchFilter(),
    int limit = 20,
    String? cursor,
  }) {
    final tokens = conversationQueryTokens(text);
    if (tokens == null || limit <= 0) return SessionSearchPage.empty;
    final fingerprint = _fingerprint(tokens, filter);
    final generation = dao.generation;
    var offset = 0;
    if (cursor != null) {
      final decoded = _decodeCursor(cursor);
      if (decoded.fingerprint != fingerprint) {
        throw ArgumentError.value(
          cursor,
          'cursor',
          'was cut for a different query or filter',
        );
      }
      if (decoded.generation != generation) throw const StaleSearchCursor();
      offset = decoded.offset;
    }
    final want = (offset + limit + 1).clamp(0, kSessionSearchDepth);
    if (offset >= want) {
      return SessionSearchPage(hits: const [], generation: generation);
    }

    final ranked =
        <
          ({RankedConversation row, ConversationMatchTier tier, String match})
        >[];
    final seen = <String>{};
    void run(ConversationMatchTier tier, String match) {
      if (ranked.length >= want) return;
      for (final row in dao.rankConversations(
        match,
        filter: filter,
        exclude: seen,
        limit: want - ranked.length,
      )) {
        if (seen.add(row.sessionId)) {
          ranked.add((row: row, tier: tier, match: match));
        }
      }
    }

    for (final step in conversationMatchCascade(text)) {
      if (step.tier == ConversationMatchTier.anyWord) break;
      run(step.tier, step.expression);
    }
    // The looser tiers answer a query the strict ones found nothing for, and
    // only then: they are what keeps a search from saying nothing, not a way
    // to pad a page the words already answered with conversations that lack
    // one of them. The vocabulary is read on that path alone.
    var repairs = const <String, String>{};
    if (ranked.isEmpty) {
      repairs = repairsFor(tokens);
      for (final tier in [
        ConversationMatchTier.repaired,
        ConversationMatchTier.anyWord,
      ]) {
        if (ranked.isNotEmpty) break;
        for (final step in conversationMatchCascade(text, repairs: repairs)) {
          if (step.tier == tier) run(step.tier, step.expression);
        }
      }
    }

    final end = (offset + limit).clamp(0, ranked.length);
    final page = ranked.sublist(offset < end ? offset : end, end);
    final turns = dao.turnsById([
      for (final entry in page) entry.row.bestTurnId,
    ]);
    final terms = _excerptTerms(tokens, repairs);

    final switched = dao.switchedRowsOf([
      for (final entry in page) entry.row.sessionId,
    ]);
    final hits = <ConversationHit>[];
    for (final entry in page) {
      final turn = turns[entry.row.bestTurnId];
      if (turn == null) continue;
      hits.add(
        ConversationHit(
          sessionId: entry.row.sessionId,
          cli: entry.row.cli,
          ordinal: turn.ordinal,
          role: turn.role,
          excerpt: conversationExcerpt(
            turn.text,
            terms.words,
            prefix: terms.prefix,
          ),
          at: turn.at,
          indexedAt: entry.row.indexedAt,
          matches: entry.row.matches,
          tier: entry.tier,
          rowId: switched[entry.row.sessionId],
        ),
      );
    }
    return SessionSearchPage(
      hits: hits,
      generation: generation,
      nextCursor: ranked.length > end && end < kSessionSearchDepth
          ? _encodeCursor(generation, end, fingerprint)
          : null,
    );
  }

  /// For each token no indexed turn contains, the nearest indexed term within
  /// an edit or two. Reads the vocabulary only for tokens that need it.
  Map<String, String> repairsFor(List<String> tokens) {
    final repairs = <String, String>{};
    for (var i = 0; i < tokens.length; i++) {
      final token = tokens[i];
      final term = token.toLowerCase();
      if (term.length < 4 || !_plainWord.hasMatch(term)) continue;
      final last = i == tokens.length - 1;
      if (dao.documentsWith(term, prefix: last) > 0) continue;
      final budget = term.length >= 8 ? 2 : 1;
      final first = String.fromCharCode(term.runes.first);
      final next = String.fromCharCode(term.runes.first + 1);
      String? best;
      var bestDistance = budget + 1;
      var bestDocs = 0;
      for (final candidate in dao.termsBetween(first, next)) {
        if ((candidate.term.length - term.length).abs() > budget) continue;
        final distance = editDistance(term, candidate.term, budget);
        if (distance > budget) continue;
        if (distance < bestDistance ||
            (distance == bestDistance && candidate.docs > bestDocs)) {
          best = candidate.term;
          bestDistance = distance;
          bestDocs = candidate.docs;
        }
      }
      if (best != null) repairs[token] = best;
    }
    return repairs;
  }

  /// Re-reads what the running sessions' transcripts appended since they were
  /// last indexed, so a search finds today's turns and not only the last
  /// trigger's. On demand, never on a timer, and at most once a
  /// [catchUpInterval]; a conversation that did not move costs one stat.
  Future<int> catchUp() {
    final indexer = this.indexer;
    if (indexer == null) return Future.value(0);
    final running = _catchingUp;
    if (running != null) return running;
    final now = clock.nowUtc();
    final last = _lastCatchUp;
    if (last != null && now.difference(last) < catchUpInterval) {
      return Future.value(0);
    }
    _lastCatchUp = now;
    return _catchingUp = _catchUp(
      indexer,
    ).whenComplete(() => _catchingUp = null);
  }

  Future<int> _catchUp(ConversationIndexer indexer) async {
    var changed = 0;
    try {
      for (final row in dao.indexedSessionConversations()) {
        if (await indexer.indexConversation(
          conversationId: row.sessionId,
          cli: row.cli,
          filePath: row.filePath,
        )) {
          changed++;
        }
      }
    } on Object {
      // A search answers from what is indexed; a transcript that could not be
      // read today is not a reason for the search itself to fail.
    }
    return changed;
  }
}

final RegExp _plainWord = RegExp(r'^[\p{L}\p{N}]+$', unicode: true);

/// A word as FTS5's `unicode61` tokenizer sees one, near enough to cut an
/// excerpt around: a run of letters and digits.
final RegExp _word = RegExp(r'[\p{L}\p{N}]+', unicode: true);

final RegExp _space = RegExp(r'\s+');

/// The lower-cased words a query looks for, and the prefix its last word is
/// still being typed as.
({Set<String> words, String? prefix}) _excerptTerms(
  List<String> tokens,
  Map<String, String> repairs,
) {
  final words = <String>{};
  String? prefix;
  for (var i = 0; i < tokens.length; i++) {
    final parts = [
      for (final m in _word.allMatches(tokens[i])) m[0]!.toLowerCase(),
    ];
    if (i == tokens.length - 1 && parts.isNotEmpty) prefix = parts.removeLast();
    words.addAll(parts);
  }
  words.addAll(repairs.values);
  return (words: words, prefix: prefix);
}

/// About [span] words of [text] around where it says the most of [words] — a
/// word starting with [prefix] counting too — with an ellipsis where it was
/// cut. Cut here rather than by FTS5's `snippet()`, which re-expands a prefix
/// query for every row it is asked about; this reads only the one turn.
String conversationExcerpt(
  String text,
  Set<String> words, {
  String? prefix,
  int span = 14,
}) {
  final found = _word.allMatches(text).toList();
  if (found.isEmpty) return text.trim();
  bool hits(RegExpMatch m) {
    final word = m[0]!.toLowerCase();
    return words.contains(word) || (prefix != null && word.startsWith(prefix));
  }

  final marks = [for (final m in found) hits(m) ? 1 : 0];
  final width = span < found.length ? span : found.length;
  var count = 0;
  for (var i = 0; i < width; i++) {
    count += marks[i];
  }
  var best = count;
  var bestStart = 0;
  for (var start = 1; start + width <= found.length; start++) {
    count += marks[start + width - 1] - marks[start - 1];
    if (count > best) {
      best = count;
      bestStart = start;
    }
  }
  // Two words of lead-in where there are any, so the match does not open the
  // line with nothing before it.
  if (best > 0 && marks[bestStart] == 1) {
    bestStart = (bestStart - 2).clamp(0, found.length - width);
  }
  final first = found[bestStart];
  final last = found[bestStart + width - 1];
  final body = text.substring(first.start, last.end).replaceAll(_space, ' ');
  return '${bestStart > 0 ? '…' : ''}$body'
      '${bestStart + width < found.length ? '…' : ''}';
}

/// Optimal-string-alignment distance between [a] and [b], or `limit + 1` as
/// soon as it is known to exceed [limit].
int editDistance(String a, String b, int limit) {
  final s = a.runes.toList();
  final t = b.runes.toList();
  if ((s.length - t.length).abs() > limit) return limit + 1;
  var prevPrev = List<int>.filled(t.length + 1, 0);
  var prev = List<int>.generate(t.length + 1, (j) => j);
  for (var i = 1; i <= s.length; i++) {
    final current = List<int>.filled(t.length + 1, 0)..[0] = i;
    var rowBest = current[0];
    for (var j = 1; j <= t.length; j++) {
      final cost = s[i - 1] == t[j - 1] ? 0 : 1;
      var value = [
        prev[j] + 1,
        current[j - 1] + 1,
        prev[j - 1] + cost,
      ].reduce((x, y) => x < y ? x : y);
      if (i > 1 &&
          j > 1 &&
          s[i - 1] == t[j - 2] &&
          s[i - 2] == t[j - 1] &&
          prevPrev[j - 2] + 1 < value) {
        value = prevPrev[j - 2] + 1;
      }
      current[j] = value;
      if (value < rowBest) rowBest = value;
    }
    if (rowBest > limit) return limit + 1;
    prevPrev = prev;
    prev = current;
  }
  return prev[t.length];
}

String _fingerprint(List<String> tokens, SessionSearchFilter filter) {
  // FNV-1a: stable across runs, unlike `String.hashCode`, so a cursor from
  // before a restart is still recognised as this search's.
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(
    '${tokens.join(' ').toLowerCase()}|${filter.fingerprint}',
  )) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16);
}

String _encodeCursor(int generation, int offset, String fingerprint) =>
    base64Url.encode(
      utf8.encode(
        jsonEncode({'v': 1, 'g': generation, 'o': offset, 'f': fingerprint}),
      ),
    );

({int generation, int offset, String fingerprint}) _decodeCursor(
  String cursor,
) {
  try {
    final json = jsonDecode(utf8.decode(base64Url.decode(cursor)));
    if (json is Map &&
        json['v'] == 1 &&
        json['g'] is int &&
        json['o'] is int &&
        (json['o'] as int) >= 0 &&
        json['f'] is String) {
      return (
        generation: json['g'] as int,
        offset: json['o'] as int,
        fingerprint: json['f'] as String,
      );
    }
  } on FormatException {
    // Falls through to the refusal below.
  }
  throw ArgumentError.value(cursor, 'cursor', 'is not a session search cursor');
}
