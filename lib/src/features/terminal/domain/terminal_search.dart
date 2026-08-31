import 'package:xterm/xterm.dart';

/// Most matches highlighted at once.
///
/// `RenderTerminal._paintHighlights` walks every highlight on every frame, so
/// the count is a per-frame cost. Beyond this the match total is still reported
/// and navigation still works — only the painting is capped.
const int kMaxSearchHighlights = 500;

/// One buffer line flattened for searching, with the mapping back to cells.
///
/// `BufferLine.getText()` skips empty cells and the trailing half of a
/// double-width glyph, so an index into it is *not* a cell column — a highlight
/// drawn there would drift left by every gap and every wide glyph before it.
/// [cellOfChar] and [widthOfChar] carry the mapping that fixes that.
class TerminalLineText {
  const TerminalLineText({
    required this.text,
    required this.cellOfChar,
    required this.widthOfChar,
  });

  /// One character per cell (a space for an empty cell), trailing blanks cut.
  final String text;

  /// Cell column of each character in [text].
  final List<int> cellOfChar;

  /// Cell width (1 or 2) of each character in [text].
  final List<int> widthOfChar;

  static const empty = TerminalLineText(
    text: '',
    cellOfChar: [],
    widthOfChar: [],
  );
}

/// Flattens [line] into searchable text plus its cell mapping.
///
/// [trimTrailing] cuts the empty tail so a query cannot match into it. Link
/// scanning turns it off for every row but the last of a wrapped run: joining
/// two rows across a trimmed gap would splice the end of one word onto the
/// start of the next and invent a token that is not on screen.
TerminalLineText lineTextOf(BufferLine line, {bool trimTrailing = true}) {
  final buffer = StringBuffer();
  final cells = <int>[];
  final widths = <int>[];

  var cell = 0;
  while (cell < line.length) {
    final codePoint = line.getCodePoint(cell);
    final width = line.getWidth(cell);
    final advance = width < 1 ? 1 : width;
    buffer.writeCharCode(codePoint == 0 ? 0x20 : codePoint);
    cells.add(cell);
    widths.add(advance);
    cell += advance;
  }

  var end = cells.length;
  final text = buffer.toString();
  while (trimTrailing && end > 0 && text.codeUnitAt(end - 1) == 0x20) {
    end--;
  }
  if (end == 0) return TerminalLineText.empty;

  return TerminalLineText(
    text: text.substring(0, end),
    cellOfChar: cells.sublist(0, end),
    widthOfChar: widths.sublist(0, end),
  );
}

/// One hit, in **cell columns**. [endColumn] is exclusive.
class ScrollbackMatch {
  const ScrollbackMatch({
    required this.line,
    required this.startColumn,
    required this.endColumn,
  });

  final int line;
  final int startColumn;
  final int endColumn;

  @override
  String toString() => 'ScrollbackMatch($line, $startColumn..$endColumn)';
}

/// Every occurrence of [query] in [lines], in reading order.
///
/// Plain substring matching; matches never span a line break.
List<ScrollbackMatch> searchLines(
  List<TerminalLineText> lines,
  String query, {
  bool caseSensitive = false,
}) {
  if (query.isEmpty) return const [];
  final needle = caseSensitive ? query : query.toLowerCase();

  final matches = <ScrollbackMatch>[];
  for (var index = 0; index < lines.length; index++) {
    final line = lines[index];
    if (line.text.isEmpty) continue;
    final haystack = caseSensitive ? line.text : line.text.toLowerCase();

    var from = 0;
    while (true) {
      final at = haystack.indexOf(needle, from);
      if (at < 0) break;
      final last = at + needle.length - 1;
      matches.add(
        ScrollbackMatch(
          line: index,
          startColumn: line.cellOfChar[at],
          endColumn: line.cellOfChar[last] + line.widthOfChar[last],
        ),
      );
      from = at + needle.length;
    }
  }
  return matches;
}
