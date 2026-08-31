/// Finding the URLs in terminal output.
///
/// **Only http and https.** Terminal output is untrusted — an agent prints
/// whatever a tool, a repository or a web page handed it — so a click must not
/// be able to reach a scheme handler. `openInBrowser` refuses anything else
/// anyway; not detecting it in the first place means the affordance never
/// appears for a link that could not be opened.
///
/// **Nothing here runs on the output path.** Detection is per *line*, and the
/// only caller runs it for the one line under the mouse pointer, so a pane that
/// is not being hovered — which is 99 of 100 — costs exactly zero. See
/// `TerminalPaneView._onHover`.
library;

import 'terminal_search.dart';

/// A URL found in one terminal line, in **cell columns**.
///
/// Columns, not character indices: `BufferLine.getText()` skips empty cells and
/// the trailing half of a double-width glyph, so the two do not agree. The
/// mapping is [TerminalLineText]'s, the same one search highlights use.
class TerminalLink {
  const TerminalLink({
    required this.url,
    required this.startColumn,
    required this.endColumn,
  });

  /// The absolute URL to open. A bare `www.…` is resolved to `https://www.…`,
  /// so this is never the raw matched text.
  final String url;

  /// First cell of the link text.
  final int startColumn;

  /// One past its last cell.
  final int endColumn;

  bool contains(int column) => column >= startColumn && column < endColumn;

  @override
  String toString() => 'TerminalLink($url, $startColumn..$endColumn)';

  @override
  bool operator ==(Object other) =>
      other is TerminalLink &&
      other.url == url &&
      other.startColumn == startColumn &&
      other.endColumn == endColumn;

  @override
  int get hashCode => Object.hash(url, startColumn, endColumn);
}

/// What a URL is allowed to be made of.
///
/// Everything up to whitespace or a delimiter that cannot appear in one:
/// angle brackets and quotes bracket URLs in prose, a backslash is a Windows
/// path separator rather than a URL one, and the C0/C1 controls are what an
/// unparsed escape sequence would leave behind.
final RegExp _urlPattern = RegExp(
  r'(?:https?://|www\.)[^\s<>"' "'" r'`\\]+',
  caseSensitive: false,
);

/// Characters a URL may not end with, because prose puts them there.
const String _trailingPunctuation = '.,;:!?*_~';

/// Closing brackets that only belong to the URL if it opened them.
const Map<String, String> _closers = {')': '(', ']': '[', '}': '{'};

/// Every http(s) URL in [line], in reading order.
List<TerminalLink> linksIn(TerminalLineText line) {
  if (line.text.isEmpty) return const [];
  final found = <TerminalLink>[];
  for (final match in _urlPattern.allMatches(line.text)) {
    final trimmed = _trimTrailing(match[0]!);
    if (trimmed.isEmpty) continue;
    final url = _resolve(trimmed);
    if (url == null) continue;
    final first = match.start;
    final last = match.start + trimmed.length - 1;
    // A match can only start and end inside the mapped region, because the
    // pattern cannot match the trailing blanks `lineTextOf` already cut.
    found.add(
      TerminalLink(
        url: url,
        startColumn: line.cellOfChar[first],
        endColumn: line.cellOfChar[last] + line.widthOfChar[last],
      ),
    );
  }
  return found;
}

/// The link under [column] on [line], or null when there is none there.
TerminalLink? linkAt(TerminalLineText line, int column) {
  for (final link in linksIn(line)) {
    if (link.contains(column)) return link;
  }
  return null;
}

/// Drops the punctuation prose left on the end of [raw].
///
/// `see https://example.com/a.` is a sentence with a URL in it, not a URL
/// ending in a full stop. A closing bracket is kept only when the URL opened
/// it, so `https://en.wikipedia.org/wiki/Foo_(bar)` survives while
/// `(https://example.com)` loses its parenthesis.
String _trimTrailing(String raw) {
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

/// The absolute http(s) URL [text] means, or null when it is not one.
///
/// A host is required, so a bare `http://` left over from a truncated line does
/// not become a clickable nothing. A *dotted* host is not required, because
/// `http://localhost:3000` is what half the dev servers an agent starts print,
/// and so is a bare IP.
String? _resolve(String text) {
  final absolute = text.toLowerCase().startsWith('www.')
      ? 'https://$text'
      : text;
  final uri = Uri.tryParse(absolute);
  if (uri == null) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  if (uri.host.isEmpty) return null;
  return absolute;
}
