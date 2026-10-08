/// Words whose full stop ends the word, not the sentence ("e.g. Python").
final _abbreviation = RegExp(
  r'(?:^|[\s(])(?:e\.g|i\.e|etc|vs|cf|approx|al|Mr|Mrs|Ms|Dr|St|No|Fig)\.$',
  caseSensitive: false,
);

/// A lone capital before a full stop is an initial ("J. Smith").
final _initial = RegExp(r'(?:^|\s)\p{Lu}\.$', unicode: true);
final _sentenceEnd = RegExp(r'''[.!?]["'”’)\]]*$''');
final _lowercase = RegExp(r'\p{Ll}', unicode: true);

/// A line's lead: indent, quote markers and a list marker.
final _lead = RegExp(r'^(\s*(?:>\s?)*)((?:[-*+]|\d{1,9}[.)])\s+)?');

final _fence = RegExp(r'^\s*(?:>\s?)*(```|~~~)');

/// Lines that are not prose: headings, tables, rules, HTML and indented code.
final _notProse = RegExp(
  r'^(?:\s*(?:>\s?)*(?:#{1,6}\s|\||<|[-*_]{3,}\s*$)| {4}|\t)',
);

/// **One sentence per line**: each sentence of [markdown]'s prose starts a
/// line of its own, as a hard break. Code, headings and tables keep theirs,
/// and nothing inside backticks or a link's brackets is split.
String oneSentencePerLine(String markdown) {
  final out = <String>[];
  var inFence = false;
  for (final line in markdown.split('\n')) {
    if (_fence.hasMatch(line)) {
      inFence = !inFence;
      out.add(line);
      continue;
    }
    if (inFence || line.trim().isEmpty || _notProse.hasMatch(line)) {
      out.add(line);
      continue;
    }
    final lead = _lead.firstMatch(line)!;
    final quote = lead[1]!;
    final marker = lead[2] ?? '';
    final body = line.substring(lead.end);
    final sentences = _sentencesOf(body);
    if (sentences.length == 1) {
      out.add(line);
      continue;
    }
    // A continuation sits under the item's text, so it stays in the item.
    final hang = '$quote${' ' * marker.length}';
    out.add('$quote$marker${sentences.first}\\');
    for (var i = 1; i < sentences.length; i++) {
      final last = i == sentences.length - 1;
      out.add('$hang${sentences[i]}${last ? '' : '\\'}');
    }
  }
  return out.join('\n');
}

List<String> _sentencesOf(String text) {
  final sentences = <String>[];
  var start = 0;
  var code = false;
  var bracket = 0;
  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (ch == '`') code = !code;
    if (code) continue;
    if (ch == '[' || ch == '(') bracket++;
    if ((ch == ']' || ch == ')') && bracket > 0) bracket--;
    if (ch != ' ' || bracket > 0) continue;
    var end = i;
    while (end < text.length && text[end] == ' ') {
      end++;
    }
    if (end >= text.length) break;
    final before = text.substring(start, i);
    if (!_endsSentence(before) || _lowercase.hasMatch(text[end])) {
      i = end - 1;
      continue;
    }
    sentences.add(before);
    start = end;
    i = end - 1;
  }
  sentences.add(text.substring(start));
  return sentences;
}

bool _endsSentence(String before) =>
    _sentenceEnd.hasMatch(before) &&
    !_abbreviation.hasMatch(before) &&
    !_initial.hasMatch(before);
