/// Finding links in terminal output. **http and https only**: terminal output
/// is untrusted, so a click must never reach a scheme handler.
library;

import 'package:xterm2/xterm.dart';

import 'package:karmashala_core/util.dart';

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

/// A path exactly as it was printed, in the spelling of whichever environment
/// printed it; `hostPathForTerminalTarget` resolves it to this machine.
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

/// One link, in **buffer rows and cell columns**: `BufferLine.getText()` skips
/// cells, so its indices are not columns, and a long link wraps onto two rows.
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

/// A wrapped run of buffer rows, flattened to scan. [rowOfChar] is what makes a
/// link crossing a row boundary one link: each character remembers its row.
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

/// How far either side of the hovered row a wrapped run is followed. A link is
/// a path or a URL, never four rows long, and an unbounded walk would flatten a
/// whole paragraph of wrapped output to answer one hover.
const int kMaxWrappedRows = 4;

/// Flattens the wrapped run of rows that [row] belongs to — a link long enough
/// to wrap would otherwise be found as two halves, each resolving to nothing.
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

/// The `OSC 8` hyperlink at ([row], [column]) as the same [TerminalLink] the
/// text scan makes, http/https only: the URI is as untrusted as the stdout.
TerminalLink? osc8LinkAt(
  Terminal terminal,
  int row,
  int column, {
  int maxRows = kMaxWrappedRows,
}) {
  final id = terminal.hyperlinkIdAt(CellOffset(column, row));
  if (id == 0) return null;
  final url = httpUrlOf(terminal.hyperlinkAt(CellOffset(column, row)) ?? '');
  if (url == null) return null;

  final lines = terminal.buffer.lines;
  var startRow = row;
  var startColumn = column;
  while (true) {
    if (startColumn > 0 &&
        lines[startRow].getHyperlinkId(startColumn - 1) == id) {
      startColumn--;
      continue;
    }
    if (startColumn > 0 || startRow == 0) break;
    if (!lines[startRow].isWrapped || row - (startRow - 1) > maxRows) break;
    final above = lines[startRow - 1];
    if (above.length == 0 || above.getHyperlinkId(above.length - 1) != id) {
      break;
    }
    startRow--;
    startColumn = above.length - 1;
  }

  var endRow = row;
  var endColumn = column + 1;
  while (true) {
    final line = lines[endRow];
    if (endColumn < line.length && line.getHyperlinkId(endColumn) == id) {
      endColumn++;
      continue;
    }
    if (endColumn < line.length || endRow + 1 >= lines.length) break;
    final below = lines[endRow + 1];
    if (!below.isWrapped || (endRow + 1) - row > maxRows) break;
    if (below.length == 0 || below.getHyperlinkId(0) != id) break;
    endRow++;
    endColumn = 1;
  }

  return TerminalLink(
    target: UrlTarget(url),
    startRow: startRow,
    startColumn: startColumn,
    endRow: endRow,
    endColumn: endColumn,
  );
}

/// What a path candidate may be made of: everything up to whitespace or a
/// character that ends a path — brackets, quotes, `=`, list and glob
/// separators.
final RegExp _tokenPattern = RegExp('[^\\s\'"`<>|*?,;=(){}\\[\\]]+');

/// A drive-letter path: `C:\src`, `c:/src`.
final RegExp _windowsAbsolute = RegExp(r'^[A-Za-z]:[\\/]');

/// The `:12` / `:12:7` a compiler or an agent puts after a path. Anchored at
/// both ends and non-greedy on the left, so a Windows drive letter's colon is
/// never mistaken for the start of a location.
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
  // contains a `/`, so a path scan would carve a second link out of one.
  final urlSpans = <(int, int)>[];
  for (final match in urlPattern.allMatches(line.text)) {
    urlSpans.add((match.start, match.end));
    final trimmed = trimTrailingPunctuation(match[0]!);
    if (trimmed.isEmpty) continue;
    // A `file://` URL is a *path*, and is resolved as one — see
    // [_fileUrlPath]. The span is claimed either way, so the path scan below
    // cannot carve a second link out of the middle of it.
    final filePath = _fileUrlPath(trimmed);
    final target = filePath != null
        ? PathTarget(filePath)
        : switch (_resolveUrl(trimmed)) {
            final url? => UrlTarget(url),
            null => null,
          };
    if (target == null) continue;
    found.add(
      _linkOf(line, target, match.start, match.start + trimmed.length),
    );
  }

  for (final match in _tokenPattern.allMatches(line.text)) {
    if (urlSpans.any((s) => match.start < s.$2 && match.end > s.$1)) continue;
    final raw = match[0]!;
    final trimmed = trimTrailingPunctuation(raw);
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

/// The path [text] is a candidate for, or null. A bare filename, a path with a
/// space and anything with a scheme are refused — a wrong guess links a word.
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

/// The absolute http(s) URL [text] means, or null. A bare `www.…` means https;
/// an `OSC 8` URI is not run through this, having written its own scheme.
String? _resolveUrl(String text) => httpUrlOf(
  text.toLowerCase().startsWith('www.') ? 'https://$text' : text,
);

/// The path a `file://` URL names — a path, never a [UrlTarget]. **A host is
/// refused**: revealing a UNC share an agent printed is an NTLM leak.
String? _fileUrlPath(String text) {
  if (!text.toLowerCase().startsWith('file://')) return null;
  final uri = Uri.tryParse(text);
  if (uri == null || uri.scheme != 'file') return null;
  if (uri.host.isNotEmpty) return null;
  final String decoded;
  try {
    decoded = Uri.decodeComponent(uri.path);
  } on ArgumentError {
    return null; // a truncated escape at the end of a wrapped line
  }
  if (decoded.isEmpty || decoded == '/') return null;
  // `/C:/Users/…` -> `C:/Users/…`; a posix path keeps its root.
  return _driveRooted.hasMatch(decoded) ? decoded.substring(1) : decoded;
}

/// `/C:/…` — a Windows path as a URL spells it, with the URL's own root slash
/// still on the front.
final RegExp _driveRooted = RegExp(r'^/[A-Za-z]:');

/// [text] if it is an absolute http(s) URL. A host is required, but not a
/// *dotted* one — `http://localhost:3000` is what dev servers print.
String? httpUrlOf(String text) {
  final uri = Uri.tryParse(text);
  if (uri == null) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  if (uri.host.isEmpty) return null;
  return text;
}
