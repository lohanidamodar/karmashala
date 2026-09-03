import 'package:xterm2/xterm.dart';

import 'terminal_search_query.dart';

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

/// Reads lines from [firstLine] through [lineAt], reporting every hit.
///
/// **This is the loop the terminal's find cost is measured in**, so it takes a
/// line *accessor* rather than a list: a caller with 100 panes must not have to
/// materialise 100 line lists to ask a question about one of them, and a cost
/// test counts the reads by counting calls to [lineAt].
///
/// Returns the number of lines actually read — the unit
/// `terminal_search_cost_test.dart` asserts on. [matchBudget] stops the scan as
/// soon as that many hits have been reported, so a query like `.` over a full
/// scrollback costs the budget rather than the buffer.
int scanLines({
  required TerminalSearchQuery query,
  required int lineCount,
  required TerminalLineText Function(int index) lineAt,
  required void Function(ScrollbackMatch match) onMatch,
  int firstLine = 0,
  int? matchBudget,
}) {
  if (!query.isUsable) return 0;

  var read = 0;
  var found = 0;
  for (var index = firstLine < 0 ? 0 : firstLine; index < lineCount; index++) {
    if (matchBudget != null && found >= matchBudget) break;
    read++;
    final line = lineAt(index);
    if (line.text.isEmpty) continue;
    query.forEachMatch(line.text, (start, end) {
      if (matchBudget != null && found >= matchBudget) return;
      final last = end - 1;
      found++;
      onMatch(
        ScrollbackMatch(
          line: index,
          startColumn: line.cellOfChar[start],
          endColumn: line.cellOfChar[last] + line.widthOfChar[last],
        ),
      );
    });
  }
  return read;
}

/// Every occurrence of [query] in [lines], in reading order.
///
/// The list-shaped convenience over [scanLines], for a caller that already has
/// its lines flattened and does not care what the scan cost.
List<ScrollbackMatch> searchLines(
  List<TerminalLineText> lines,
  String query, {
  bool caseSensitive = false,
}) {
  final matches = <ScrollbackMatch>[];
  scanLines(
    query: TerminalSearchQuery.parse(query, caseSensitive: caseSensitive),
    lineCount: lines.length,
    lineAt: (index) => lines[index],
    onMatch: matches.add,
  );
  return matches;
}
