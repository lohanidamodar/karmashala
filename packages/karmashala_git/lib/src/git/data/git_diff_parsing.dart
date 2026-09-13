import 'dart:convert';

import '../domain/diff_line.dart';
import '../domain/diff_stat.dart';
import '../domain/file_change.dart';
import '../domain/git_commit.dart';
import '../domain/working_tree_status.dart';

/// Parses `git status --porcelain=v1` output into [FileChange]s.
///
/// **The seven conflict pairs are read as a pair, not letter by letter.** v1 has
/// no record for an unmerged path, so `AA` came out *added* and `DD` *deleted* —
/// a confident wrong verb about a file the merge has not finished with.
List<FileChange> parseGitStatus(String porcelain) {
  final changes = <FileChange>[];
  for (final raw in porcelain.split(RegExp(r'[\r\n]'))) {
    if (raw.length < 4) continue;
    final x = raw[0];
    final y = raw[1];
    final rest = raw.substring(3);

    String? originalPath;
    var path = rest;
    if (rest.contains(' -> ')) {
      final parts = rest.split(' -> ');
      originalPath = unquoteGitPath(parts.first);
      path = parts.last;
    }
    path = unquoteGitPath(path);

    final conflict = MergeConflict.ofCode('$x$y');
    if (conflict != MergeConflict.unrecorded) {
      changes.add(
        FileChange(
          path: path,
          originalPath: originalPath,
          type: FileChangeType.conflicted,
          conflict: conflict,
          staged: true,
          unstaged: true,
        ),
      );
      continue;
    }

    final untracked = x == '?' && y == '?';
    final staged = !untracked && x != ' ';
    final unstaged = untracked || y != ' ';
    final code = untracked ? '?' : (x != ' ' ? x : y);

    changes.add(
      FileChange(
        path: path,
        originalPath: originalPath,
        type: _typeOf(code),
        staged: staged,
        unstaged: unstaged,
      ),
    );
  }
  return changes;
}

FileChangeType _typeOf(String code) => switch (code) {
  'A' => FileChangeType.added,
  'M' => FileChangeType.modified,
  'D' => FileChangeType.deleted,
  'R' => FileChangeType.renamed,
  'C' => FileChangeType.copied,
  '?' => FileChangeType.untracked,
  _ => FileChangeType.unknown,
};

/// Parses `git log --pretty=format:%H%x1f%an%x1f%s` output (unit-separated
/// fields, one commit per line) into [GitCommit]s.
List<GitCommit> parseGitLog(String output) {
  final unitSeparator = String.fromCharCode(0x1f); // %x1f in the format string
  final commits = <GitCommit>[];
  for (final line in output.split(RegExp(r'[\r\n]+'))) {
    if (line.isEmpty) continue;
    final parts = line.split(unitSeparator);
    if (parts.length < 3) continue;
    commits.add(GitCommit(sha: parts[0], author: parts[1], subject: parts[2]));
  }
  return commits;
}

/// Parses unified diff text into classified [DiffLine]s for display.
List<DiffLine> parseUnifiedDiff(String diff) {
  final lines = <DiffLine>[];
  for (final line in diff.split('\n')) {
    final DiffLineKind kind;
    if (line.startsWith('@@')) {
      kind = DiffLineKind.hunk;
    } else if (line.startsWith('+++') ||
        line.startsWith('---') ||
        line.startsWith('diff ') ||
        line.startsWith('index ') ||
        line.startsWith('new file') ||
        line.startsWith('deleted file') ||
        line.startsWith('rename ') ||
        line.startsWith('similarity ')) {
      kind = DiffLineKind.meta;
    } else if (line.startsWith('+')) {
      kind = DiffLineKind.added;
    } else if (line.startsWith('-')) {
      kind = DiffLineKind.removed;
    } else {
      kind = DiffLineKind.context;
    }
    lines.add(DiffLine(kind, line));
  }
  // Drop a single trailing empty context line from the final newline.
  if (lines.isNotEmpty &&
      lines.last.kind == DiffLineKind.context &&
      lines.last.text.isEmpty) {
    lines.removeLast();
  }
  return lines;
}

/// The line number each row of [lines] occupies **in the new file**, or null
/// for a row that is not a line of it.
///
/// Null for a header, a hunk marker and — deliberately — every **removed** line,
/// which is not in the new file at all. `\ No newline at end of file` is skipped;
/// counting it would shift every number after it by one.
List<int?> newFileLineNumbers(List<DiffLine> lines) {
  final numbers = List<int?>.filled(lines.length, null);
  var next = 0;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    switch (line.kind) {
      case DiffLineKind.hunk:
        next = _newStartOf(line.text) ?? 0;
      case DiffLineKind.added || DiffLineKind.context:
        // Before the first hunk header there is no numbering to be had, and a
        // guess would be a fabricated anchor.
        if (next == 0) continue;
        if (line.text.startsWith(r'\')) continue;
        numbers[i] = next;
        next++;
      case DiffLineKind.removed || DiffLineKind.meta:
        continue;
    }
  }
  return numbers;
}

/// The `+c` of a `@@ -a,b +c,d @@` header, or null when it does not parse.
int? _newStartOf(String header) {
  final match = RegExp(r'^@@ -\d+(?:,\d+)? \+(\d+)').firstMatch(header);
  if (match == null) return null;
  return int.tryParse(match.group(1)!);
}

/// Parses `git diff --name-status` output into [FileChange]s.
///
/// Two committed states, so nothing here is staged or unstaged — both flags are
/// false, and a caller that cares about the index uses [parseGitStatus].
List<FileChange> parseNameStatus(String output) {
  final changes = <FileChange>[];
  for (final line in output.split(RegExp(r'[\r\n]+'))) {
    if (line.isEmpty) continue;
    final parts = line.split('\t');
    if (parts.length < 2) continue;
    final code = parts.first;
    // R100 / C75 carry a similarity score and a second path.
    final renamed = code.startsWith('R') || code.startsWith('C');
    changes.add(
      FileChange(
        path: unquoteGitPath(renamed && parts.length > 2 ? parts[2] : parts[1]),
        originalPath: renamed && parts.length > 2
            ? unquoteGitPath(parts[1])
            : null,
        type: _typeOf(code[0]),
        staged: false,
        unstaged: false,
      ),
    );
  }
  return changes;
}

/// Parses `git diff --numstat` output — `added<TAB>removed<TAB>path` per file.
///
/// A binary file reports `-` for both counts: counted as a file and as a binary
/// file, contributing no lines.
DiffStat parseNumstat(String output) {
  var added = 0;
  var removed = 0;
  var files = 0;
  var binary = 0;
  for (final line in output.split(RegExp(r'[\r\n]+'))) {
    if (line.isEmpty) continue;
    final parts = line.split('\t');
    if (parts.length < 3) continue;
    files++;
    final a = int.tryParse(parts[0]);
    final r = int.tryParse(parts[1]);
    if (a == null || r == null) {
      binary++;
      continue;
    }
    added += a;
    removed += r;
  }
  return DiffStat(
    added: added,
    removed: removed,
    files: files,
    binaryFiles: binary,
  );
}

/// Parses `git rev-list --left-right --count <base>...HEAD` — two counts on one
/// line, left (behind) then right (ahead).
///
/// Returns null for anything that is not two numbers, which is what an
/// unresolvable base ref produces. "Could not tell" must never read as zero.
AheadBehind? parseAheadBehind(String output) {
  final parts = output.trim().split(RegExp(r'\s+'));
  if (parts.length != 2) return null;
  final behind = int.tryParse(parts[0]);
  final ahead = int.tryParse(parts[1]);
  if (behind == null || ahead == null) return null;
  return AheadBehind(ahead: ahead, behind: behind);
}

/// Parses `git status --porcelain=v2 --branch`.
///
/// **v2 for its header lines.** `branch.ab` is absent — so the distance is
/// **null, not zero** — for a branch with no upstream and for one whose upstream
/// has gone; level with an upstream is `+0 -0`, stated.
///
/// v2 writes `.` where v1 wrote a space, and a `u` record's `<XY>` is a conflict
/// pair for [MergeConflict.ofCode], not a pair of status letters.
WorkingTreeStatus parseGitStatusV2(String porcelain) {
  String? branch;
  String? upstream;
  int? ahead;
  int? behind;
  final changes = <FileChange>[];

  for (final line in porcelain.split(RegExp(r'[\r\n]'))) {
    if (line.isEmpty) continue;
    if (line.startsWith('# ')) {
      final header = line.substring(2);
      if (header.startsWith(_branchHead)) {
        final value = header.substring(_branchHead.length).trim();
        // `(detached)` is git's word for "no branch", and the only other thing
        // this field ever holds is a branch name.
        branch = value == '(detached)' ? null : value;
      } else if (header.startsWith(_branchUpstream)) {
        upstream = header.substring(_branchUpstream.length).trim();
      } else if (header.startsWith(_branchAb)) {
        final counts = _abPattern.firstMatch(
          header.substring(_branchAb.length).trim(),
        );
        if (counts != null) {
          ahead = int.parse(counts.group(1)!);
          behind = int.parse(counts.group(2)!);
        }
      }
      continue;
    }
    final change = _v2Record(line);
    if (change != null) changes.add(change);
  }

  return WorkingTreeStatus(
    branch: (branch?.isEmpty ?? true) ? null : branch,
    upstream: (upstream?.isEmpty ?? true) ? null : upstream,
    aheadOfUpstream: ahead,
    behindUpstream: behind,
    changes: changes,
  );
}

const _branchHead = 'branch.head ';
const _branchUpstream = 'branch.upstream ';
const _branchAb = 'branch.ab ';
final _abPattern = RegExp(r'^\+(\d+)\s+-(\d+)$');

/// One entry line of `--porcelain=v2`, or null for a line that is not one.
///
/// The field counts are git's, and the **last** field is always the path, which
/// is why they are counted rather than split: a path may contain spaces.
FileChange? _v2Record(String line) {
  switch (line[0]) {
    // 1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
    case '1':
      final fields = _v2Fields(line, 9);
      return fields == null ? null : _v2Change(fields[1], fields[8]);
    // 2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>\t<origPath>
    case '2':
      final fields = _v2Fields(line, 10);
      if (fields == null) return null;
      // **The tab**, which v1 never writes. Splitting the last field on
      // whitespace would fold two paths into one and undercount the change.
      final tab = fields[9].indexOf('\t');
      return _v2Change(
        fields[1],
        tab < 0 ? fields[9] : fields[9].substring(0, tab),
        originalPath: tab < 0 ? null : fields[9].substring(tab + 1),
      );
    // u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>
    // **One path, always.** `<XY>` says which sides of the merge hold the file;
    // a rename is a `2`, and git writes the conflicted path once.
    case 'u':
      final fields = _v2Fields(line, 11);
      if (fields == null) return null;
      return FileChange(
        path: unquoteGitPath(fields[10]),
        type: FileChangeType.conflicted,
        conflict: MergeConflict.ofCode(fields[1]),
        // Both: an unmerged path has entries in the index *and* a working-tree
        // file that differs from all of them.
        staged: true,
        unstaged: true,
      );
    // ? <path>
    case '?':
      if (line.length < 3) return null;
      return FileChange(
        path: unquoteGitPath(line.substring(2)),
        type: FileChangeType.untracked,
        staged: false,
        unstaged: true,
      );
    // `! <path>` is an ignored file, listed only for `--ignored`, which nothing
    // here asks for. Anything else is a line this parse does not know.
    default:
      return null;
  }
}

/// [line] as exactly [count] fields, the last one taking the whole remainder,
/// or null when there are not that many.
List<String>? _v2Fields(String line, int count) {
  final fields = <String>[];
  var start = 0;
  for (var i = 0; i < count - 1; i++) {
    final space = line.indexOf(' ', start);
    if (space < 0) return null;
    fields.add(line.substring(start, space));
    start = space + 1;
  }
  if (start >= line.length) return null;
  fields.add(line.substring(start));
  return fields;
}

/// A `<XY>` field and a path as a [FileChange].
///
/// `.` is v2's "unmodified" where v1 wrote a space; every other letter is v1's,
/// so [_typeOf] is shared.
FileChange _v2Change(String xy, String path, {String? originalPath}) {
  final x = xy.isNotEmpty ? xy[0] : '.';
  final y = xy.length > 1 ? xy[1] : '.';
  return FileChange(
    path: unquoteGitPath(path),
    originalPath: originalPath == null ? null : unquoteGitPath(originalPath),
    type: _typeOf(x != '.' ? x : y),
    staged: x != '.',
    unstaged: y != '.',
  );
}

/// Parses `git diff --numstat` output as one entry per file, keyed by the path
/// git printed.
///
/// A rename is keyed by its **new** path, which is what `git status` calls the
/// file, so a caller can look a row up by the name it already has.
Map<String, FileDiffStat> parseNumstatByFile(String output) {
  final stats = <String, FileDiffStat>{};
  for (final line in output.split(RegExp(r'[\r\n]+'))) {
    if (line.isEmpty) continue;
    final parts = line.split('\t');
    if (parts.length < 3) continue;
    // A tab-separated rename puts the new path last; otherwise there is one.
    // git quotes a path containing a tab, so an unquoted field never holds one.
    final path = unquoteGitPath(
      _numstatNewPath(parts.length > 3 ? parts.last : parts[2]),
    );
    if (path.isEmpty) continue;
    stats[path] = FileDiffStat(
      added: int.tryParse(parts[0]),
      removed: int.tryParse(parts[1]),
    );
  }
  return stats;
}

/// The **new** name of the file a `--numstat` path field describes — see
/// `docs/SETTLED.md` for the rename shapes git writes.
String _numstatNewPath(String field) {
  final brace = field.indexOf('{');
  final arrow = field.indexOf(' => ', brace < 0 ? 0 : brace);
  if (arrow < 0) return field;
  if (brace < 0) return field.substring(arrow + 4);
  final close = field.indexOf('}', arrow);
  if (close < 0) return field;
  final prefix = field.substring(0, brace);
  final middle = field.substring(arrow + 4, close);
  final suffix = field.substring(close + 1);
  if (middle.isEmpty && prefix.endsWith('/') && suffix.startsWith('/')) {
    return prefix + suffix.substring(1);
  }
  return prefix + middle + suffix;
}

/// A path field as git printed it, with C-style quoting undone; a field git did
/// not quote is returned unchanged.
///
/// Done here rather than with `-c core.quotePath=false`: the escapes are ASCII
/// whatever the path's bytes are, and the raw UTF-8 that flag emits instead is
/// mangled by `systemEncoding` on the way back from a Windows process.
String unquoteGitPath(String field) {
  if (field.length < 2 || !field.startsWith('"') || !field.endsWith('"')) {
    return field;
  }
  final bytes = <int>[];
  var i = 1;
  final end = field.length - 1;
  while (i < end) {
    final char = field.codeUnitAt(i++);
    if (char != _backslash) {
      // Everything git escapes is ASCII; anything else is passed through as
      // the UTF-8 it will be decoded back out of below.
      if (char < 0x80) {
        bytes.add(char);
      } else {
        bytes.addAll(utf8.encode(String.fromCharCode(char)));
      }
      continue;
    }
    if (i >= end) break;
    final escaped = field.codeUnitAt(i++);
    final octal = _octalDigit(escaped);
    if (octal == null) {
      bytes.add(_cEscapes[escaped] ?? escaped);
      continue;
    }
    var value = octal;
    for (var digit = 1; digit < 3 && i < end; digit++) {
      final next = _octalDigit(field.codeUnitAt(i));
      if (next == null) break;
      value = value * 8 + next;
      i++;
    }
    bytes.add(value & 0xff);
  }
  // Lenient: a half-escaped field is one wrong character, not a lost path.
  return utf8.decode(bytes, allowMalformed: true);
}

const int _backslash = 0x5c;

/// git's own C escapes, `\<letter>` to the byte it stands for.
const Map<int, int> _cEscapes = {
  0x61: 0x07, // \a
  0x62: 0x08, // \b
  0x66: 0x0c, // \f
  0x6e: 0x0a, // \n
  0x72: 0x0d, // \r
  0x74: 0x09, // \t
  0x76: 0x0b, // \v
};

int? _octalDigit(int char) => char >= 0x30 && char <= 0x37 ? char - 0x30 : null;
