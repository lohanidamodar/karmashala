import '../agents/domain/file_edit.dart';

/// The most text, in UTF-16 code units across every edit of one call, that a
/// transcript row keeps. A `Write` of a generated file is megabytes, and the
/// transcript is re-read on a poll.
const int kMaxToolEditChars = 64 * 1024;

/// The most edits one call keeps; a patch over hundreds of files is cut here.
const int kMaxToolEdits = 32;

/// Unchanged lines kept on each side of a change when a whole-file pair is
/// reduced to the region that differs.
const int kToolEditContextLines = 3;

/// [edits] within [kMaxToolEdits] and [kMaxToolEditChars], and whether
/// anything that differs had to be dropped.
///
/// A pair of whole files is first reduced to its changed region, which loses
/// nothing a diff shows; only what is still over the budget is cut, at a line
/// end.
(List<FileEditRecord>, bool) boundedToolEdits(List<FileEditRecord> edits) {
  if (edits.isEmpty) return (const [], false);
  var cut = edits.length > kMaxToolEdits;
  var kept = cut ? edits.sublist(0, kMaxToolEdits) : edits;
  if (!cut && _size(kept) <= kMaxToolEditChars) return (kept, false);

  kept = [for (final edit in kept) _changedRegion(edit)];
  if (_size(kept) <= kMaxToolEditChars) return (kept, cut);

  final share = kMaxToolEditChars ~/ kept.length;
  final bounded = <FileEditRecord>[];
  for (final edit in kept) {
    final sides = [edit.oldText, edit.newText, edit.recordedDiff].nonNulls;
    final each = sides.isEmpty ? share : share ~/ sides.length;
    final (oldText, oldCut) = _headLines(edit.oldText, each);
    final (newText, newCut) = _headLines(edit.newText, each);
    final (diff, diffCut) = _headLines(edit.recordedDiff, each);
    cut |= oldCut || newCut || diffCut;
    bounded.add(
      FileEditRecord(
        path: edit.path,
        kind: edit.kind,
        toolName: edit.toolName,
        oldText: oldText,
        newText: newText,
        recordedDiff: diff,
        renamedTo: edit.renamedTo,
      ),
    );
  }
  return (bounded, cut);
}

int _size(List<FileEditRecord> edits) {
  var total = 0;
  for (final edit in edits) {
    total +=
        (edit.oldText?.length ?? 0) +
        (edit.newText?.length ?? 0) +
        (edit.recordedDiff?.length ?? 0);
  }
  return total;
}

/// [edit] with the lines both sides share, beyond [kToolEditContextLines] of
/// context, taken off its head and tail. Unchanged when it is not a pair.
FileEditRecord _changedRegion(FileEditRecord edit) {
  final oldText = edit.oldText;
  final newText = edit.newText;
  if (oldText == null || newText == null || edit.recordedDiff != null) {
    return edit;
  }
  final before = oldText.split('\n');
  final after = newText.split('\n');
  var head = 0;
  while (head < before.length &&
      head < after.length &&
      before[head] == after[head]) {
    head++;
  }
  var tail = 0;
  while (tail < before.length - head &&
      tail < after.length - head &&
      before[before.length - 1 - tail] == after[after.length - 1 - tail]) {
    tail++;
  }
  final skipHead = head > kToolEditContextLines
      ? head - kToolEditContextLines
      : 0;
  final skipTail = tail > kToolEditContextLines
      ? tail - kToolEditContextLines
      : 0;
  if (skipHead == 0 && skipTail == 0) return edit;
  return FileEditRecord(
    path: edit.path,
    kind: edit.kind,
    toolName: edit.toolName,
    oldText: before.sublist(skipHead, before.length - skipTail).join('\n'),
    newText: after.sublist(skipHead, after.length - skipTail).join('\n'),
    renamedTo: edit.renamedTo,
  );
}

/// The whole lines of [text] that fit in [limit] code units, and whether any
/// were left off.
(String?, bool) _headLines(String? text, int limit) {
  if (text == null || text.length <= limit) return (text, false);
  final end = text.lastIndexOf('\n', limit);
  return (end <= 0 ? text.substring(0, limit) : text.substring(0, end), true);
}
