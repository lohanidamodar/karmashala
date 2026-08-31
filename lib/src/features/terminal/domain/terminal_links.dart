/// Finding the links in terminal output: URLs, and the file paths an agent's
/// output is mostly made of.
///
/// **Only http and https, for URLs.** Terminal output is untrusted — an agent
/// prints whatever a tool, a repository or a web page handed it — so a click
/// must not be able to reach a scheme handler. `openInBrowser` refuses anything
/// else anyway; not detecting it in the first place means the affordance never
/// appears for a link that could not be opened.
///
/// **Nothing here runs on the output path, or on a frame.** Detection is per
/// *line*, and the only caller runs it for the one line under the mouse pointer
/// *while Ctrl is held*. A pane nobody is Ctrl-hovering — which is all of them,
/// almost all of the time — costs exactly zero. See `TerminalPaneView`.
///
/// **Nothing here touches the filesystem.** A [PathTarget] is a candidate, not
/// a fact: it is text that is shaped like a path. Whether anything is actually
/// there is one `stat` of one candidate, made by the pane after this returns
/// and never during a scan.
library;

import 'package:xterm/xterm.dart';

import 'terminal_search.dart';

/// What a link points at.
sealed class TerminalTarget {
  const TerminalTarget();

  /// How the target is written for the user.
  String get label;
}

/// An absolute http(s) URL. A bare `www.…` is resolved to `https://www.…`, so
/// [url] is never the raw matched text.
class UrlTarget extends TerminalTarget {
  const UrlTarget(this.url);

  final String url;

  @override
  String get label => url;

  @override
  String toString() => 'UrlTarget($url)';

  @override
  bool operator ==(Object other) => other is UrlTarget && other.url == url;

  @override
  int get hashCode => url.hashCode;
}

/// A path, exactly as it was printed — absolute or relative, in whichever
/// environment's spelling the program that printed it uses.
///
/// Resolving that to somewhere on this machine is `hostPathForTerminalTarget`'s
/// job, because it needs the pane (its working directory and its shell) and
/// this file only has the line.
///
/// [line] and [column] are the `path:12` / `path:12:7` suffix compilers and
/// agents emit. They are carried even though nothing honours them yet: dropping
/// them here would mean re-parsing the text to get them back.
class PathTarget extends TerminalTarget {
  const PathTarget(this.path, {this.line, this.column});

  final String path;
  final int? line;
  final int? column;

  @override
  String get label => switch ((line, column)) {
    (null, _) => path,
    (final l?, null) => '$path:$l',
    (final l?, final c?) => '$path:$l:$c',
  };

  @override
  String toString() => 'PathTarget($label)';

  @override
  bool operator ==(Object other) =>
      other is PathTarget &&
      other.path == path &&
      other.line == line &&
      other.column == column;

  @override
  int get hashCode => Object.hash(path, line, column);
}

/// One link found in terminal output, in **buffer rows and cell columns**.
///
/// Columns, not character indices: `BufferLine.getText()` skips empty cells and
/// the trailing half of a double-width glyph, so the two do not agree. The
/// mapping is [TerminalLinkLine]'s, the same one search highlights use.
///
/// Rows, plural, because a link that was too long for the row it started on
/// continues on the next one — which `\\wsl.localhost\…` paths routinely are.
/// [startRow] and [endRow] are equal for the ordinary case.
class TerminalLink {
  const TerminalLink({
    required this.target,
    required this.startRow,
    required this.startColumn,
    required this.endRow,
    required this.endColumn,
  });

  final TerminalTarget target;

  /// Buffer row and cell of the first character.
  final int startRow;
  final int startColumn;

  /// Buffer row of the last character, and one cell past it.
  final int endRow;
  final int endColumn;

  bool contains(int row, int column) {
    if (row < startRow || row > endRow) return false;
    if (row == startRow && column < startColumn) return false;
    if (row == endRow && column >= endColumn) return false;
    return true;
  }

  @override
  String toString() =>
      'TerminalLink($target, $startRow:$startColumn..$endRow:$endColumn)';

  @override
  bool operator ==(Object other) =>
      other is TerminalLink &&
      other.target == target &&
      other.startRow == startRow &&
      other.startColumn == startColumn &&
      other.endRow == endRow &&
      other.endColumn == endColumn;

  @override
  int get hashCode =>
      Object.hash(target, startRow, startColumn, endRow, endColumn);
}

/// A wrapped run of buffer rows, flattened into one string to scan.
///
/// [rowOfChar] is what makes a link that crosses a row boundary one link: every
/// character remembers which row it came from, so a match's two ends can be put
/// back on the buffer as anchors.
class TerminalLinkLine {
  const TerminalLinkLine({
    required this.text,
    required this.rowOfChar,
    required this.cellOfChar,
    required this.widthOfChar,
  });

  /// One character per cell (a space for an empty cell).
  final String text;

  /// Buffer row of each character in [text].
  final List<int> rowOfChar;

  /// Cell column of each character within its own row.
  final List<int> cellOfChar;

  /// Cell width (1 or 2) of each character.
  final List<int> widthOfChar;

  static const empty = TerminalLinkLine(
    text: '',
    rowOfChar: [],
    cellOfChar: [],
    widthOfChar: [],
  );
}

/// How far either side of the hovered row a wrapped run is followed.
///
/// A link is a path or a URL; neither is four full terminal rows long, and an
/// unbounded walk would flatten a whole paragraph of wrapped output to answer
/// one hover.
const int kMaxWrappedRows = 4;

/// Flattens the wrapped run of rows that [row] belongs to.
///
/// `BufferLine.isWrapped` marks a row as the continuation of the one above it,
/// so a link long enough to wrap spans two rows and would otherwise be found as
/// two halves, each of which resolves to nothing.
TerminalLinkLine linkLineAt(
  Buffer buffer,
  int row, {
  int maxRows = kMaxWrappedRows,
}) {
  final lines = buffer.lines;
  if (row < 0 || row >= lines.length) return TerminalLinkLine.empty;

  var first = row;
  while (first > 0 &&
      lines[first].isWrapped &&
      row - (first - 1) <= maxRows) {
    first--;
  }
  var last = row;
  while (last + 1 < lines.length &&
      lines[last + 1].isWrapped &&
      (last + 1) - row <= maxRows) {
    last++;
  }

  // The overwhelmingly common case: one unwrapped row, no joining to do.
  if (first == last) {
    final flat = lineTextOf(lines[row]);
    return TerminalLinkLine(
      text: flat.text,
      rowOfChar: List<int>.filled(flat.text.length, row),
      cellOfChar: flat.cellOfChar,
      widthOfChar: flat.widthOfChar,
    );
  }

  final joined = StringBuffer();
  final rows = <int>[];
  final cells = <int>[];
  final widths = <int>[];
  for (var y = first; y <= last; y++) {
    // Only the last row's empty tail is cut: trimming an inner row would splice
    // the end of one row onto the start of the next across a gap of blanks.
    final flat = lineTextOf(lines[y], trimTrailing: y == last);
    joined.write(flat.text);
    for (var i = 0; i < flat.text.length; i++) {
      rows.add(y);
    }
    cells.addAll(flat.cellOfChar);
    widths.addAll(flat.widthOfChar);
  }
  return TerminalLinkLine(
    text: joined.toString(),
    rowOfChar: rows,
    cellOfChar: cells,
    widthOfChar: widths,
  );
}

/// What a URL is allowed to be made of.
///
/// Everything up to whitespace or a delimiter that cannot appear in one:
/// angle brackets and quotes bracket URLs in prose, a backslash is a Windows
/// path separator rather than a URL one, and the C0/C1 controls are what an
/// unparsed escape sequence would leave behind.
final RegExp _urlPattern = RegExp(
  r'(?:https?://|www\.)[^\s<>"' "'" r'`\\]+',
  caseSensitive: false,
);

/// What a path candidate is allowed to be made of: everything up to whitespace
/// or a character that ends a path in practice.
///
/// Brackets and quotes are breaks rather than something to trim afterwards, so
/// `(lib/main.dart:42)` and `"C:\src\app"` come out as the path itself. `=` is a
/// break so `--out=build/app` offers the path. `,`, `;`, `|`, `*` and `?` are
/// separators in lists, shell pipelines and globs, none of which is one path.
final RegExp _tokenPattern = RegExp('[^\\s\'"`<>|*?,;=(){}\\[\\]]+');

/// Characters a URL may not end with, because prose puts them there.
const String _trailingPunctuation = '.,;:!?*_~';

/// Closing brackets that only belong to the URL if it opened them.
const Map<String, String> _closers = {')': '(', ']': '[', '}': '{'};

/// A drive-letter path: `C:\src`, `c:/src`.
final RegExp _windowsAbsolute = RegExp(r'^[A-Za-z]:[\\/]');

/// The `:12` / `:12:7` a compiler or an agent puts after a path.
///
/// Anchored at both ends and non-greedy on the left, so the colon in `C:\src`
/// is never mistaken for the start of a location.
final RegExp _locationSuffix = RegExp(r'^(.+?):(\d+)(?::(\d+))?$');

final RegExp _hasSeparator = RegExp(r'[\\/]');
final RegExp _hasWordChar = RegExp(r'[A-Za-z0-9]');
final RegExp _startsPath = RegExp(r'^[A-Za-z0-9._~@+#$%-]');

/// Every link in [line], in reading order: URLs first-served, then the path
/// candidates in whatever is left.
List<TerminalLink> linksIn(TerminalLinkLine line) {
  if (line.text.isEmpty) return const [];
  final found = <TerminalLink>[];

  // URLs are matched first and their spans are then off limits: every URL
  // contains a `/`, so a path scan would otherwise carve a second link out of
  // the middle of one.
  final urlSpans = <(int, int)>[];
  for (final match in _urlPattern.allMatches(line.text)) {
    urlSpans.add((match.start, match.end));
    final trimmed = _trimTrailing(match[0]!);
    if (trimmed.isEmpty) continue;
    final url = _resolveUrl(trimmed);
    if (url == null) continue;
    found.add(
      _linkOf(line, UrlTarget(url), match.start, match.start + trimmed.length),
    );
  }

  for (final match in _tokenPattern.allMatches(line.text)) {
    if (urlSpans.any((s) => match.start < s.$2 && match.end > s.$1)) continue;
    final raw = match[0]!;
    final trimmed = _trimTrailing(raw);
    if (trimmed.isEmpty) continue;
    final target = _pathTargetOf(trimmed);
    if (target == null) continue;
    found.add(
      _linkOf(line, target, match.start, match.start + trimmed.length),
    );
  }

  found.sort((a, b) {
    final byRow = a.startRow.compareTo(b.startRow);
    return byRow != 0 ? byRow : a.startColumn.compareTo(b.startColumn);
  });
  return found;
}

/// The link at ([row], [column]) on [line], or null when there is none there.
TerminalLink? linkAt(TerminalLinkLine line, int row, int column) {
  for (final link in linksIn(line)) {
    if (link.contains(row, column)) return link;
  }
  return null;
}

/// Builds a link from the half-open character range `[first, end)`.
TerminalLink _linkOf(
  TerminalLinkLine line,
  TerminalTarget target,
  int first,
  int end,
) {
  final last = end - 1;
  return TerminalLink(
    target: target,
    startRow: line.rowOfChar[first],
    startColumn: line.cellOfChar[first],
    endRow: line.rowOfChar[last],
    endColumn: line.cellOfChar[last] + line.widthOfChar[last],
  );
}

/// The path [text] is a candidate for, or null when it is not one.
///
/// Deliberately **not** matched, because the cost of a wrong guess is a link
/// under a word that is not one:
///
/// * a bare filename with no separator — `Node.js` and `e.g.` are the same
///   shape as `pubspec.yaml`, and there is no way to tell them apart from the
///   text alone;
/// * a path containing a space — `C:\Program Files\…` cannot be told from two
///   words, and quoting it is not something output reliably does;
/// * anything with a scheme in it, which is a URL and already handled above.
PathTarget? _pathTargetOf(String text) {
  if (text.contains('://')) return null;
  final match = _locationSuffix.firstMatch(text);
  final path = match?.group(1) ?? text;
  if (!_looksLikePath(path)) return null;
  final line = match?.group(2);
  final column = match?.group(3);
  return PathTarget(
    path,
    line: line == null ? null : int.tryParse(line),
    column: column == null ? null : int.tryParse(column),
  );
}

bool _looksLikePath(String text) {
  if (text.isEmpty) return false;
  if (_windowsAbsolute.hasMatch(text)) return true;
  if (text.startsWith(r'\\')) return text.length > 2;
  if (text.startsWith('//')) return false;
  if (text.startsWith('/')) return text.length > 1;
  if (!_hasSeparator.hasMatch(text)) return false;
  if (!_hasWordChar.hasMatch(text)) return false;
  return _startsPath.hasMatch(text);
}

/// Drops the punctuation prose left on the end of [raw].
///
/// `see https://example.com/a.` is a sentence with a URL in it, not a URL
/// ending in a full stop, and `edit lib/main.dart.` is the same sentence about
/// a file. A closing bracket is kept only when the text opened it, so
/// `https://en.wikipedia.org/wiki/Foo_(bar)` survives.
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
String? _resolveUrl(String text) {
  final absolute = text.toLowerCase().startsWith('www.')
      ? 'https://$text'
      : text;
  final uri = Uri.tryParse(absolute);
  if (uri == null) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  if (uri.host.isEmpty) return null;
  return absolute;
}
