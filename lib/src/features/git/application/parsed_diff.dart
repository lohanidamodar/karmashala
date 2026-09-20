import 'package:karmashala_git/git.dart';
import 'package:riverpod/riverpod.dart';

import 'diff_tab_actions.dart';

/// The most rows a diff is drawn as. Past this a patch stops being something
/// anybody reads line by line, and building every row costs more than the
/// reading is worth — but a view that quietly stopped at the cap would look
/// like the whole change, which is the one thing it must not do.
const int kDiffRowLimit = 20000;

/// One file's unified diff, parsed once: its rows, the new-file line each row
/// is, the `+N −M` it adds up to, and its widest row.
class ParsedDiff {
  ParsedDiff._(
    this.lines,
    this.newLineNumbers,
    this.added,
    this.removed,
    this.widestLine,
    this.totalLines,
  );

  /// Parses [text], materialising at most [maxLines] rows.
  ///
  /// The counts are taken over **the whole patch** whether or not every row is
  /// kept: `+N −M` is a true statement about the change, and a number that
  /// silently described only the visible part would be worse than no number.
  /// [widestLine] is measured over the kept rows alone, because it sizes a
  /// scroll for what is actually on screen.
  factory ParsedDiff.parse(String text, {int maxLines = kDiffRowLimit}) {
    final all = parseUnifiedDiff(text);
    var added = 0;
    var removed = 0;
    for (final line in all) {
      if (line.kind == DiffLineKind.added) added++;
      if (line.kind == DiffLineKind.removed) removed++;
    }
    final lines = all.length > maxLines ? all.sublist(0, maxLines) : all;
    var widest = '';
    for (final line in lines) {
      if (line.text.length > widest.length) widest = line.text;
    }
    return ParsedDiff._(
      lines,
      newFileLineNumbers(lines),
      added,
      removed,
      widest,
      all.length,
    );
  }

  /// The rows being drawn — [totalLines] of them unless [isPartial].
  final List<DiffLine> lines;
  final List<int?> newLineNumbers;

  /// Added and removed lines in the **whole** patch, not only in [lines].
  final int added;
  final int removed;

  /// The row with the most characters — what the horizontal scroll is sized
  /// from, measured once in the diff's own monospace style.
  final String widestLine;

  /// How many rows the patch has in total.
  final int totalLines;

  /// Whether rows were left out. The view must say so where it says anything
  /// else about the diff: what is shown is not the whole change.
  bool get isPartial => totalLines > lines.length;

  /// Rows the patch has and this rendering does not.
  int get omittedLines => totalLines - lines.length;
}

/// [diffForTargetProvider], parsed. Watched by the header and the body both,
/// so neither re-parses the patch when the tab rebuilds.
final parsedDiffProvider = Provider.autoDispose
    .family<AsyncValue<ParsedDiff>, DiffTarget>(
      (ref, target) => ref
          .watch(diffForTargetProvider(target))
          .whenData((text) => ParsedDiff.parse(text)),
    );
