import 'dart:convert';

import 'package:karmashala_git/git.dart' show DiffLine, DiffLineKind;

/// Unchanged lines a hunk keeps on each side of its change; a longer quiet
/// stretch between two changes splits them into two hunks.
const int kHunkContext = 3;

/// One change in a diff, as lines: what the file held [before] and holds
/// [after] over the same stretch, context included.
class EditHunk {
  const EditHunk({
    required this.path,
    required this.index,
    required this.before,
    required this.after,
    required this.firstChange,
    this.added = 0,
    this.removed = 0,
    this.header,
    this.newStart,
  });

  final String path;

  /// Its place among the file's hunks, from 0.
  final int index;
  final List<String> before;
  final List<String> after;

  /// The index into the diff's lines of its first added or removed line —
  /// never folded away, so the hunk's controls sit just above it.
  final int firstChange;

  /// The index of its `@@` line, where it has one.
  final int? header;

  /// The 1-based line [after] starts at in the file, where the diff says.
  final int? newStart;

  final int added;
  final int removed;

  /// Stable across runs and devices: what a Keep mark is filed under.
  String get key => hunkKey(path, before, after);
}

/// FNV-1a over [path] and both sides: the same change always has the same key.
String hunkKey(String path, List<String> before, List<String> after) {
  var hash = 0xcbf29ce484222325;
  const prime = 0x100000001b3;
  for (final unit in utf8.encode(
    '$path\u0000${before.join('\n')}\u0001'
    '${after.join('\n')}',
  )) {
    hash ^= unit;
    hash = (hash * prime) & 0xFFFFFFFFFFFFFFFF;
  }
  return hash.toUnsigned(64).toRadixString(16).padLeft(16, '0');
}

final _header = RegExp(r'^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@');

/// The hunks of [lines], a diff of the file at [path]: split at each `@@`, and
/// within one wherever more than twice [kHunkContext] unchanged lines part two
/// changes. A diff with no change has none.
List<EditHunk> diffHunks(String path, List<DiffLine> lines) {
  final out = <EditHunk>[];
  // Sections between headers; a diff of excerpts has a single, headerless one.
  var i = 0;
  while (i < lines.length) {
    int? header;
    int? start;
    if (lines[i].kind == DiffLineKind.hunk) {
      header = i;
      start = int.tryParse(_header.firstMatch(lines[i].text)?.group(1) ?? '');
      i++;
    } else if (lines[i].kind == DiffLineKind.meta) {
      i++;
      continue;
    }
    final from = i;
    while (i < lines.length &&
        lines[i].kind != DiffLineKind.hunk &&
        lines[i].kind != DiffLineKind.meta) {
      i++;
    }
    _splitSection(lines, from, i, header, start, path, out);
  }
  return out;
}

void _splitSection(
  List<DiffLine> lines,
  int from,
  int to,
  int? header,
  int? newStart,
  String path,
  List<EditHunk> out,
) {
  bool changed(int k) =>
      lines[k].kind == DiffLineKind.added ||
      lines[k].kind == DiffLineKind.removed;
  final changes = [
    for (var k = from; k < to; k++)
      if (changed(k)) k,
  ];
  if (changes.isEmpty) return;
  // Groups of changes no more than twice the context apart.
  final groups = <(int, int)>[];
  var first = changes.first;
  var last = first;
  for (final k in changes.skip(1)) {
    if (k - last - 1 > 2 * kHunkContext) {
      groups.add((first, last));
      first = k;
    }
    last = k;
  }
  groups.add((first, last));

  for (var g = 0; g < groups.length; g++) {
    final (lo, hi) = groups[g];
    final start = g == 0 ? from : (lo - kHunkContext).clamp(from, lo);
    final end = g == groups.length - 1
        ? to
        : (hi + 1 + kHunkContext).clamp(hi + 1, to);
    final before = <String>[];
    final after = <String>[];
    var added = 0;
    var removed = 0;
    // The new-side line of [start]: the section's own start plus every line
    // before it that the new file has.
    var at = newStart;
    if (at != null) {
      for (var k = from; k < start; k++) {
        if (lines[k].kind != DiffLineKind.removed) at = at! + 1;
      }
    }
    for (var k = start; k < end; k++) {
      final line = lines[k];
      final text = line.text.isEmpty ? '' : line.text.substring(1);
      switch (line.kind) {
        case DiffLineKind.added:
          after.add(text);
          added++;
        case DiffLineKind.removed:
          before.add(text);
          removed++;
        case DiffLineKind.context:
          // A context line is ` text`; an empty one may have lost its space.
          final plain = line.text.startsWith(' ') ? text : line.text;
          before.add(plain);
          after.add(plain);
        default:
          break;
      }
    }
    out.add(
      EditHunk(
        path: path,
        index: out.length,
        before: before,
        after: after,
        firstChange: lo,
        added: added,
        removed: removed,
        header: g == 0 ? header : null,
        newStart: at,
      ),
    );
  }
}

/// What putting one hunk back did to a file's text.
sealed class HunkRevert {
  const HunkRevert();
}

final class HunkReverted extends HunkRevert {
  const HunkReverted(this.text);
  final String text;
}

/// The file no longer holds the hunk's new lines, or holds them in more than
/// one place with nothing to say which: it changed since that turn.
final class HunkConflict extends HunkRevert {
  const HunkConflict(this.reason);
  final String reason;
}

/// [text] with [hunk] put back — its new lines replaced by its old ones —
/// found where the diff says, or anywhere they occur exactly once.
HunkRevert revertHunk(String text, EditHunk hunk) {
  final crlf = text.contains('\r\n');
  final endsWithNewline = text.endsWith('\n');
  final body = endsWithNewline ? text.substring(0, text.length - 1) : text;
  final lines = text.isEmpty
      ? <String>[]
      : [
          for (final line in body.split('\n'))
            crlf && line.endsWith('\r')
                ? line.substring(0, line.length - 1)
                : line,
        ];
  final after = hunk.after;
  if (after.isEmpty) {
    return const HunkConflict(
      'This change only removed lines and kept no lines around them, so '
      'there is nowhere to tell to put them back.',
    );
  }
  final found = <int>[];
  for (var i = 0; i + after.length <= lines.length; i++) {
    var same = true;
    for (var k = 0; k < after.length; k++) {
      if (lines[i + k] != after[k]) {
        same = false;
        break;
      }
    }
    if (same) found.add(i);
  }
  if (found.isEmpty && hunk.header == null) {
    // An excerpt's first and last lines may be parts of lines.
    final normal = crlf ? text.replaceAll('\r\n', '\n') : text;
    final wrote = after.join('\n');
    final first = normal.indexOf(wrote);
    if (first >= 0 && normal.indexOf(wrote, first + 1) < 0) {
      final put = normal.replaceRange(
        first,
        first + wrote.length,
        hunk.before.join('\n'),
      );
      return HunkReverted(crlf ? put.replaceAll('\n', '\r\n') : put);
    }
  }
  if (found.isEmpty) {
    return const HunkConflict(
      'The file changed since that turn: the lines this change wrote are not '
      'in it any more.',
    );
  }
  int? at;
  if (found.length == 1) {
    at = found.single;
  } else if (hunk.newStart case final start?) {
    at = found.contains(start - 1) ? start - 1 : null;
  }
  if (at == null) {
    return const HunkConflict(
      'The lines this change wrote are in the file more than once, so it '
      'cannot tell which to put back.',
    );
  }
  final next = [
    ...lines.sublist(0, at),
    ...hunk.before,
    ...lines.sublist(at + after.length),
  ];
  final eol = crlf ? '\r\n' : '\n';
  final joined = next.join(eol);
  return HunkReverted(
    endsWithNewline && next.isNotEmpty ? '$joined$eol' : joined,
  );
}

/// [text] with every one of [hunks] put back, last first so earlier ones
/// keep their place; the first that no longer applies stops it, changing
/// nothing.
HunkRevert revertHunks(String text, List<EditHunk> hunks) {
  var current = text;
  for (final hunk in hunks.reversed) {
    switch (revertHunk(current, hunk)) {
      case HunkReverted(:final text):
        current = text;
      case final HunkConflict conflict:
        return conflict;
    }
  }
  return HunkReverted(current);
}
