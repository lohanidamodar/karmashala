import 'package:karmashala_git/git.dart';
import 'package:riverpod/riverpod.dart';

import 'diff_tab_actions.dart';

/// One file's unified diff, parsed once: its rows, the new-file line each row
/// is, the `+N −M` it adds up to, and its widest row.
class ParsedDiff {
  ParsedDiff._(
    this.lines,
    this.newLineNumbers,
    this.added,
    this.removed,
    this.widestLine,
  );

  factory ParsedDiff.parse(String text) {
    final lines = parseUnifiedDiff(text);
    var added = 0;
    var removed = 0;
    var widest = '';
    for (final line in lines) {
      if (line.kind == DiffLineKind.added) added++;
      if (line.kind == DiffLineKind.removed) removed++;
      if (line.text.length > widest.length) widest = line.text;
    }
    return ParsedDiff._(
      lines,
      newFileLineNumbers(lines),
      added,
      removed,
      widest,
    );
  }

  final List<DiffLine> lines;
  final List<int?> newLineNumbers;
  final int added;
  final int removed;

  /// The row with the most characters — what the horizontal scroll is sized
  /// from, measured once in the diff's own monospace style.
  final String widestLine;
}

/// [diffForTargetProvider], parsed. Watched by the header and the body both,
/// so neither re-parses the patch when the tab rebuilds.
final parsedDiffProvider = Provider.autoDispose
    .family<AsyncValue<ParsedDiff>, DiffTarget>(
      (ref, target) =>
          ref.watch(diffForTargetProvider(target)).whenData(ParsedDiff.parse),
    );
