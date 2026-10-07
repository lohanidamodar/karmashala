/// What an agent's own working line says while a turn runs — Claude Code's
/// `✻ Sautéing… (12s · ↓ 1.2k tokens)`, Codex's `• Working (3s • esc to
/// interrupt)`, or the turn an ACP agent was prompted for. Each part is null
/// where nothing carried it; none is ever made up.
class AgentWorkingDetail {
  const AgentWorkingDetail({this.word, this.since, this.tokens});

  /// The agent's own word for what it is doing, verbatim ("Sautéing…").
  final String? word;

  /// When the turn began: the line's elapsed time counted back from when it
  /// was read, or when the turn was prompted.
  final DateTime? since;

  /// The tokens the agent says this turn has streamed.
  final int? tokens;

  bool get isEmpty => word == null && since == null && tokens == null;

  AgentWorkingDetail withSince(DateTime? since) =>
      AgentWorkingDetail(word: word, since: since, tokens: tokens);

  /// Whether [other] says the same at the grain a reader sees: the word, the
  /// start within [sinceSlack] (a count in whole seconds, read at another
  /// moment, lands up to a second either way) and the tokens as drawn.
  bool sameAs(AgentWorkingDetail? other) {
    if (other == null) return false;
    if (word != other.word) return false;
    if (_tokenGrain(tokens) != _tokenGrain(other.tokens)) return false;
    final a = since;
    final b = other.since;
    if (a == null || b == null) return a == b;
    return a.difference(b).abs() < sinceSlack;
  }

  static const Duration sinceSlack = Duration(seconds: 2);

  Map<String, Object?> toJson() => {
    'word': ?word,
    if (since case final since?) 'since': since.toUtc().toIso8601String(),
    'tokens': ?tokens,
  };

  /// Null for anything but a map, and for a map that says nothing.
  static AgentWorkingDetail? fromJson(Object? json) {
    if (json is! Map) return null;
    final word = json['word'];
    final since = json['since'];
    final tokens = json['tokens'];
    final detail = AgentWorkingDetail(
      word: word is String && word.isNotEmpty ? word : null,
      since: since is String ? DateTime.tryParse(since)?.toUtc() : null,
      tokens: tokens is int ? tokens : null,
    );
    return detail.isEmpty ? null : detail;
  }

  @override
  String toString() => 'AgentWorkingDetail($word, $since, $tokens)';
}

/// Exact below a thousand, then two significant figures: the count a compact
/// label draws, so a count that moves within it is not news.
int? _tokenGrain(int? tokens) {
  if (tokens == null || tokens < 1000) return tokens;
  var step = 1;
  while (tokens ~/ step >= 100) {
    step *= 10;
  }
  return tokens ~/ step * step;
}

/// **How to read an agent's working line** off the bottom of its screen:
/// `<glyph> <word> (<elapsed> <sep> <part> <sep> …)`. Two agents' lines, read
/// off real PTY captures, differ only in the separator and in what tells the
/// line from text the agent printed.
class WorkingLineRule {
  const WorkingLineRule({
    required this.separator,
    this.wordSuffix,
    this.requiredPart,
  });

  /// Between the parts inside the parentheses: Claude Code's `·`, Codex's `•`.
  final String separator;

  /// What the word always ends in — Claude Code's `…`. Null asks nothing.
  final String? wordSuffix;

  /// A part the line always carries — Codex's `esc to interrupt`. Null asks
  /// nothing.
  final String? requiredPart;

  /// The lowest line of [tailLines] that is a working line, read as at [now];
  /// null when none is.
  AgentWorkingDetail? read(List<String> tailLines, DateTime now) {
    for (var i = tailLines.length - 1; i >= 0; i--) {
      final detail = readLine(tailLines[i], now);
      if (detail != null) return detail;
    }
    return null;
  }

  /// [line] read as a working line, or null when it is not one. A line still
  /// being drawn (no closing parenthesis yet) is not one.
  AgentWorkingDetail? readLine(String line, DateTime now) {
    final text = line.trim();
    if (!text.endsWith(')')) return null;
    // The first ` (` whose inside opens on an elapsed time: Codex's MCP line
    // has `(0/2)` before it.
    for (
      var open = text.indexOf(' (');
      open >= 0;
      open = text.indexOf(' (', open + 1)
    ) {
      final inside = text.substring(open + 2, text.length - 1);
      final parts = [for (final part in inside.split(separator)) part.trim()];
      final elapsed = _elapsed(parts.first);
      if (elapsed == null) continue;
      final required = requiredPart?.toLowerCase();
      if (required != null &&
          !parts.any((part) => part.toLowerCase().contains(required))) {
        return null;
      }
      final word = _word(text.substring(0, open));
      if (word == null) return null;
      int? tokens;
      for (final part in parts.skip(1)) {
        tokens ??= _tokens(part);
      }
      return AgentWorkingDetail(
        word: word,
        since: now.subtract(elapsed),
        tokens: tokens,
      );
    }
    return null;
  }

  /// The word, its spinner glyph taken off; null unless it opens on a
  /// capital, as both agents' words do — a reply's text rarely ends `…  (3s)`.
  String? _word(String head) {
    var word = head.trim();
    final space = word.indexOf(' ');
    if (space > 0 && !_letter.hasMatch(word.substring(0, space))) {
      word = word.substring(space + 1).trim();
    }
    if (word.isEmpty || !_capital.hasMatch(word)) return null;
    final suffix = wordSuffix;
    if (suffix != null && !word.endsWith(suffix)) return null;
    return word;
  }

  static final _letter = RegExp(r'[\p{L}\p{N}]', unicode: true);
  static final _capital = RegExp(r'^\p{Lu}', unicode: true);
  static final _elapsedShape = RegExp(r'^(?:(\d+)h\s*)?(?:(\d+)m\s*)?(\d+)s$');
  static final _tokenShape = RegExp(
    r'^[↑↓]?\s*(\d[\d,]*(?:\.\d+)?)\s*([kKmM])?\s+tokens$',
  );

  static Duration? _elapsed(String part) {
    final match = _elapsedShape.firstMatch(part);
    if (match == null) return null;
    int at(int group) => int.parse(match.group(group) ?? '0');
    return Duration(hours: at(1), minutes: at(2), seconds: at(3));
  }

  static int? _tokens(String part) {
    final match = _tokenShape.firstMatch(part);
    if (match == null) return null;
    final number = double.tryParse(match.group(1)!.replaceAll(',', ''));
    if (number == null) return null;
    final scale = switch (match.group(2)?.toLowerCase()) {
      'k' => 1000,
      'm' => 1000000,
      _ => 1,
    };
    return (number * scale).round();
  }
}
