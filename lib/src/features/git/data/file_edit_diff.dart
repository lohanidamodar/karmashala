/// Turning a [FileEditRecord] into the same rows the Changes panel draws.
///
/// The output is [DiffLine]s produced by [parseUnifiedDiff] — the parser the
/// Git panel already uses — so an agent's edit and a working-tree change are
/// classified by one set of rules and drawn by one widget. Two diffs that look
/// different in one app is a defect on its own.
///
/// ## The budget, and why there is one
///
/// This runs on the UI isolate, so a diff that takes a visible moment is a
/// window that stops moving. Three limits keep that impossible, in the order
/// they are cheapest to check:
///
/// * [kFileEditMaxBytes] — past this, nothing is diffed at all and the size is
///   reported instead ([FileEditDiffStatus.tooLarge]).
/// * [kFileEditMaxCells] — the alignment is `O(n*m)`, so a rewrite past this
///   many cells degrades to "all of the old, then all of the new". A coarse
///   diff, never a missing one and never a hang.
/// * [kFileEditMaxLines] — how many rows are handed to the widget. The rest is
///   counted but not built.
///
/// The ordinary case costs none of it: Claude Code and Codex both record a
/// finished patch, and [FileEditRecord.recordedDiff] is rendered as-is.
library;

import 'dart:typed_data';

import '../domain/diff_line.dart';
import '../domain/file_edit.dart';
import 'git_diff_parsing.dart';

/// The most content, per side, that is worth diffing.
const int kFileEditMaxBytes = 512 * 1024;

/// The most diff rows handed to the widget; beyond this the diff is truncated
/// and says so.
const int kFileEditMaxLines = 4000;

/// The alignment budget, in `old lines * new lines`.
const int kFileEditMaxCells = 250000;

/// How many diffs [buildFileEditDiff] has actually computed.
///
/// Exposed so a test can prove that rebuilding a transcript re-renders without
/// re-diffing; nothing in the app reads it.
int fileEditDiffComputations = 0;

/// Why a record has no rows to show, when it has none.
enum FileEditDiffStatus {
  /// There is a diff and it is in [FileEditDiff.lines].
  ok,

  /// The write changed no line — an edit that replaced text with itself.
  empty,

  /// The content is not text, so there is nothing a line diff can say.
  binary,

  /// Past the budget: the change is real but was not diffed.
  tooLarge,
}

/// A [FileEditRecord] rendered down to displayable rows.
class FileEditDiff {
  const FileEditDiff({
    required this.record,
    required this.status,
    required this.lines,
    required this.unified,
    required this.added,
    required this.removed,
    required this.totalLines,
  });

  final FileEditRecord record;
  final FileEditDiffStatus status;

  /// The rows to draw, already classified. Empty for every status but
  /// [FileEditDiffStatus.ok].
  final List<DiffLine> lines;

  /// The whole diff as text, untruncated — what a "copy diff" action copies.
  final String unified;

  final int added;
  final int removed;

  /// Rows the diff has in total, which is more than `lines.length` when it was
  /// truncated.
  final int totalLines;

  String get path => record.path;
  FileEditKind get kind => record.kind;

  /// Whether [lines] is only the head of the diff.
  bool get truncated => totalLines > lines.length;
}

/// The diff for [record], computed once and remembered.
FileEditDiff buildFileEditDiff(FileEditRecord record) {
  final cached = _memo[record];
  if (cached != null) return cached;

  fileEditDiffComputations++;
  final diff = _build(record);
  // Insertion-ordered, so the oldest entry is the first key. A transcript
  // scrolls through far more edits than are ever on screen, and holding every
  // diff it has passed would hold every file it has passed with it.
  if (_memo.length >= _memoLimit) _memo.remove(_memo.keys.first);
  _memo[record] = diff;
  return diff;
}

/// Empties the memo. For tests, which must not see each other's counts.
void clearFileEditDiffCache() {
  _memo.clear();
  fileEditDiffComputations = 0;
}

// --- internals ---------------------------------------------------------------

const int _memoLimit = 128;
final Map<FileEditRecord, FileEditDiff> _memo = {};

FileEditDiff _build(FileEditRecord record) {
  final recorded = record.recordedDiff;
  if (recorded != null && recorded.isNotEmpty) {
    return _fromUnified(record, recorded);
  }

  final oldText = record.oldText;
  final newText = record.newText;
  if (_looksBinary(oldText) || _looksBinary(newText)) {
    return _blank(record, FileEditDiffStatus.binary);
  }
  if ((oldText?.length ?? 0) > kFileEditMaxBytes ||
      (newText?.length ?? 0) > kFileEditMaxBytes) {
    return _blank(record, FileEditDiffStatus.tooLarge);
  }

  final before = _splitLines(oldText);
  final after = _splitLines(newText);
  if (before.isEmpty && after.isEmpty) {
    return _blank(record, FileEditDiffStatus.empty);
  }

  // A whole-file create or delete has real line numbers, so it gets a real
  // hunk header. A modification we had to diff ourselves does not: its texts
  // came from an `Edit`'s `old_string`/`new_string`, which are excerpts with no
  // position in the file, and a `@@ -1,3 +1,3 @@` over an excerpt is a lie a
  // reader would act on. See [FileEditRecord.isFragment].
  final body = <String>[];
  String? header;
  if (before.isEmpty) {
    header = '@@ -0,0 +1,${after.length} @@';
    body.addAll(after.map((l) => '+$l'));
  } else if (after.isEmpty) {
    header = '@@ -1,${before.length} +0,0 @@';
    body.addAll(before.map((l) => '-$l'));
  } else {
    body.addAll(_alignLines(before, after));
  }

  return _fromUnified(record, [?header, ...body].join('\n'));
}

FileEditDiff _fromUnified(FileEditRecord record, String unified) {
  final all = unified.split('\n');
  var added = 0;
  var removed = 0;
  for (final line in all) {
    // `+++`/`---` are file headers, not content; nothing here writes them, but
    // a recorded patch from a future CLI version might.
    if (line.startsWith('+') && !line.startsWith('+++')) {
      added++;
    } else if (line.startsWith('-') && !line.startsWith('---')) {
      removed++;
    }
  }
  if (added == 0 && removed == 0) {
    return _blank(record, FileEditDiffStatus.empty, unified: unified);
  }

  final shown = all.length > kFileEditMaxLines
      ? all.sublist(0, kFileEditMaxLines).join('\n')
      : unified;
  return FileEditDiff(
    record: record,
    status: FileEditDiffStatus.ok,
    lines: parseUnifiedDiff(shown),
    unified: unified,
    added: added,
    removed: removed,
    totalLines: all.length,
  );
}

FileEditDiff _blank(
  FileEditRecord record,
  FileEditDiffStatus status, {
  String unified = '',
}) => FileEditDiff(
  record: record,
  status: status,
  lines: const [],
  unified: unified,
  added: 0,
  removed: 0,
  totalLines: 0,
);

/// [text] as lines, without the empty string a trailing newline leaves behind.
List<String> _splitLines(String? text) {
  if (text == null || text.isEmpty) return const [];
  final lines = text.split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  return lines;
}

/// Whether [text] is bytes rather than source.
///
/// A NUL is git's own test, and `U+FFFD` is what a UTF-8 decode leaves where
/// the bytes were never text — which is how a binary file reaches us at all,
/// since it arrives already decoded out of JSON. Only the head is examined: a
/// file whose first 8 KB are clean text is text for this purpose.
bool _looksBinary(String? text) {
  if (text == null) return false;
  final limit = text.length < 8000 ? text.length : 8000;
  for (var i = 0; i < limit; i++) {
    final unit = text.codeUnitAt(i);
    if (unit == 0 || unit == 0xFFFD) return true;
  }
  return false;
}

/// Lines of [before] and [after] aligned into ` `/`-`/`+` rows.
List<String> _alignLines(List<String> before, List<String> after) {
  // Matching heads and tails need no alignment and are most of every edit.
  var start = 0;
  while (start < before.length &&
      start < after.length &&
      before[start] == after[start]) {
    start++;
  }
  var endBefore = before.length;
  var endAfter = after.length;
  while (endBefore > start &&
      endAfter > start &&
      before[endBefore - 1] == after[endAfter - 1]) {
    endBefore--;
    endAfter--;
  }

  final out = <String>[
    for (var i = 0; i < start; i++) ' ${before[i]}',
  ];
  final middleBefore = before.sublist(start, endBefore);
  final middleAfter = after.sublist(start, endAfter);
  if (middleBefore.isEmpty || middleAfter.isEmpty) {
    out.addAll(middleBefore.map((l) => '-$l'));
    out.addAll(middleAfter.map((l) => '+$l'));
  } else if (middleBefore.length * middleAfter.length > kFileEditMaxCells) {
    // Over budget: say the middle was replaced wholesale rather than spend
    // seconds finding out exactly how.
    out.addAll(middleBefore.map((l) => '-$l'));
    out.addAll(middleAfter.map((l) => '+$l'));
  } else {
    out.addAll(_longestCommonSubsequenceDiff(middleBefore, middleAfter));
  }
  for (var i = endBefore; i < before.length; i++) {
    out.add(' ${before[i]}');
  }
  return out;
}

/// The classic LCS alignment, bounded by [kFileEditMaxCells] before it is
/// called.
///
/// Filled from the end so the walk forward can choose the branch with more
/// common lines left in it, which is what keeps a `-`/`+` pair adjacent
/// instead of pushing every removal to the top.
List<String> _longestCommonSubsequenceDiff(
  List<String> before,
  List<String> after,
) {
  final rows = before.length;
  final columns = after.length;
  final stride = columns + 1;
  final table = Int32List((rows + 1) * stride);
  for (var i = rows - 1; i >= 0; i--) {
    for (var j = columns - 1; j >= 0; j--) {
      table[i * stride + j] = before[i] == after[j]
          ? table[(i + 1) * stride + j + 1] + 1
          : (table[(i + 1) * stride + j] >= table[i * stride + j + 1]
                ? table[(i + 1) * stride + j]
                : table[i * stride + j + 1]);
    }
  }

  final out = <String>[];
  var i = 0;
  var j = 0;
  while (i < rows && j < columns) {
    if (before[i] == after[j]) {
      out.add(' ${before[i]}');
      i++;
      j++;
    } else if (table[(i + 1) * stride + j] >= table[i * stride + j + 1]) {
      out.add('-${before[i]}');
      i++;
    } else {
      out.add('+${after[j]}');
      j++;
    }
  }
  while (i < rows) {
    out.add('-${before[i++]}');
  }
  while (j < columns) {
    out.add('+${after[j++]}');
  }
  return out;
}
