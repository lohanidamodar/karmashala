/// Finding URLs in ordinary text, for every surface that shows some — one regex
/// rather than one per surface, which would drift.
///
/// **Only http and https**: a note's body is often text an agent wrote, so a
/// click must not reach an arbitrary scheme handler. A `file://` stays plain
/// text; only the terminal, which has a working directory, resolves one.
library;

/// What a URL is allowed to be made of: everything up to whitespace or a
/// delimiter that cannot appear in one — quotes and angle brackets bracket URLs
/// in prose, and a backslash is a Windows path separator.
final RegExp urlPattern = RegExp(
  r'(?:https?://|file://|www\.)[^\s<>"' "'" r'`\\]+',
  caseSensitive: false,
);

/// Characters a URL may not end with, because prose puts them there — emphasis
/// marks included, since agents write markdown into terminals and notes alike.
const _trailingPunctuation = '.,;:!?*_~';

/// Closing brackets that belong to the URL only if it opened them, so
/// `(https://example.com/a)` loses its bracket and `…/Foo_(bar)` keeps its own.
const _closers = {')': '(', ']': '[', '}': '{'};

/// [raw] with the punctuation that belongs to the surrounding prose removed.
String trimTrailingPunctuation(String raw) {
  var end = raw.length;
  while (end > 0) {
    final char = raw[end - 1];
    if (_trailingPunctuation.contains(char)) {
      end--;
      continue;
    }
    final opener = _closers[char];
    if (opener != null &&
        _countOf(raw, opener, end) < _countOf(raw, char, end)) {
      end--;
      continue;
    }
    break;
  }
  return raw.substring(0, end);
}

int _countOf(String text, String char, int end) {
  var count = 0;
  for (var i = 0; i < end; i++) {
    if (text[i] == char) count++;
  }
  return count;
}

/// [text] if it is an absolute http(s) URL, and null otherwise. A host is
/// required so a truncated `http://` is not clickable; a *dotted* host is not,
/// because `http://localhost:3000` and bare IPs are what dev servers print.
String? httpUrlOf(String text) {
  final uri = Uri.tryParse(text);
  if (uri == null) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  if (uri.host.isEmpty) return null;
  return text;
}

/// The absolute http(s) URL a scanned [text] means, or null when it is not one.
/// A bare `www.…` from the scan means https.
String? resolveHttpUrl(String text) => httpUrlOf(
  text.toLowerCase().startsWith('www.') ? 'https://$text' : text,
);

/// One URL found in a plain string, with where it sits in it.
class TextLink {
  const TextLink({required this.url, required this.start, required this.end});

  /// The absolute URL — never the raw matched text, since a bare `www.` was
  /// resolved to https on the way here.
  final String url;

  /// Offsets into the string the link was found in, for styling and hit-testing.
  final int start;
  final int end;

  @override
  bool operator ==(Object other) =>
      other is TextLink &&
      other.url == url &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(url, start, end);

  @override
  String toString() => 'TextLink($url, $start..$end)';
}

/// Every http(s) URL in [text], in the order they appear.
List<TextLink> linksInText(String text) {
  final found = <TextLink>[];
  for (final match in urlPattern.allMatches(text)) {
    final trimmed = trimTrailingPunctuation(match[0]!);
    if (trimmed.isEmpty) continue;
    final url = resolveHttpUrl(trimmed);
    if (url == null) continue;
    found.add(
      TextLink(url: url, start: match.start, end: match.start + trimmed.length),
    );
  }
  return found;
}
