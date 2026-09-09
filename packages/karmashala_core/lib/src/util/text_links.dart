/// Finding URLs in ordinary text, for every surface that shows some.
///
/// These primitives were the terminal's, and the terminal still uses exactly
/// these: `features/terminal/domain/terminal_links.dart` imports them rather
/// than keeping its own copy. They moved down here when notes and todos needed
/// links too, because the alternative was a second regex, and two regexes are
/// two answers to "is this a URL" that drift apart.
///
/// **Only http and https.** The terminal's rule, and it holds here for the same
/// reason: a note's body is often text an agent wrote, so a click must not be
/// able to reach an arbitrary scheme handler. A `file://` in a note is left as
/// plain text; the terminal resolves one as a *path* because it has a pane's
/// working directory and an environment to translate against, and a note has
/// neither.
library;

/// What a URL is allowed to be made of.
///
/// Everything up to whitespace or a delimiter that cannot appear in one: angle
/// brackets and quotes bracket URLs in prose, a backslash is a Windows path
/// separator rather than a URL one, and the C0/C1 controls are what an unparsed
/// escape sequence would leave behind.
final RegExp urlPattern = RegExp(
  r'(?:https?://|file://|www\.)[^\s<>"' "'" r'`\\]+',
  caseSensitive: false,
);

/// Characters a URL may not end with, because prose puts them there. The
/// emphasis marks are here because agents write markdown into terminals and
/// into notes alike.
const _trailingPunctuation = '.,;:!?*_~';

/// Closing brackets that only belong to the URL if it opened them, so
/// `(https://example.com/a)` loses its bracket and
/// `https://en.wikipedia.org/wiki/Foo_(bar)` keeps its own. Quotes and angle
/// brackets are absent deliberately: [urlPattern] cannot match them, so one
/// can never be the last character.
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

/// [text] if it is an absolute http(s) URL, and null otherwise.
///
/// A host is required, so a bare `http://` left over from a truncated line does
/// not become a clickable nothing. A *dotted* host is not required, because
/// `http://localhost:3000` is what half the dev servers an agent starts print,
/// and so is a bare IP.
String? httpUrlOf(String text) {
  final uri = Uri.tryParse(text);
  if (uri == null) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  if (uri.host.isEmpty) return null;
  return text;
}

/// The absolute http(s) URL a scanned [text] means, or null when it is not one.
///
/// A bare `www.…` is what the scan may hand over, and it means https.
String? resolveHttpUrl(String text) => httpUrlOf(
  text.toLowerCase().startsWith('www.') ? 'https://$text' : text,
);

/// One URL found in a plain string, with where it sits in it.
class TextLink {
  const TextLink({required this.url, required this.start, required this.end});

  /// The absolute URL — never the raw matched text, since a bare `www.` was
  /// resolved to https on the way here.
  final String url;

  /// Offsets into the string the link was found in, so a caller can style
  /// exactly those characters and hit-test them.
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
