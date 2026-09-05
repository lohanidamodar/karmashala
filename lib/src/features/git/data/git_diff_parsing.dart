import '../domain/diff_line.dart';
import '../domain/diff_stat.dart';
import '../domain/file_change.dart';
import '../domain/git_commit.dart';
import '../domain/working_tree_status.dart';

/// Parses `git status --porcelain=v1` output into [FileChange]s.
///
/// Each line is `XY <path>` where `X` is the index (staged) status and `Y` the
/// work-tree (unstaged) status. `??` marks untracked; `R`/`C` lines carry
/// `old -> new`. Pure and testable.
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
      originalPath = parts.first;
      path = parts.last;
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
/// This is the translation that makes a review comment anchorable. The row
/// index a widget builder has is a position in a rendering — it is what the old
/// `DiffAnnotation.diffIndex` stored, and it is meaningless the moment the diff
/// is regenerated. The number this returns is a position in the *file*, which
/// together with the file's content hash is a claim that can be checked later
/// (see `review_thread.dart`).
///
/// Null for a header, a hunk marker, and — deliberately — for every **removed**
/// line. A removed line is not in the new file at all, so there is no line
/// number that could honestly be given for it. Handing back the number of the
/// line that follows the deletion would be an anchor onto text the comment was
/// not about, which is the exact failure mode this feature exists to remove;
/// the caller turns a comment on a removed line into a file-level thread that
/// quotes the removed text instead.
///
/// `\ No newline at end of file` is git's annotation, not a line of the file,
/// and is skipped — counting it would shift every number after it by one.
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
/// This is a comparison between two committed states, so nothing in it is
/// "staged" or "unstaged" — both flags are false, and callers that care about
/// the index use [parseGitStatus] instead.
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
        path: renamed && parts.length > 2 ? parts[2] : parts[1],
        originalPath: renamed && parts.length > 2 ? parts[1] : null,
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
/// A binary file reports `-` for both counts; it is counted as a file and as a
/// binary file, and contributes no lines. Rename entries can carry NUL-separated
/// paths under `-z`, which this deliberately does not ask for: the counts are
/// the point, and the path is only used to know a row happened.
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
/// **v2 rather than v1, for the three header lines v1 does not have.** v1
/// squeezes the branch, its upstream and their divergence into one `## ` line
/// and a bracket — `## work...origin/work [ahead 2, behind 1]` — which has to
/// be taken apart by string surgery, and which says nothing at all when the
/// branch is level. v2 states each fact on its own line:
///
/// ```txt
/// # branch.oid 3f2a…            (or `(initial)` before the first commit)
/// # branch.head work            (or `(detached)`)
/// # branch.upstream origin/work (absent when the branch has no upstream)
/// # branch.ab +2 -1             (absent when git cannot compute it)
/// ```
///
/// So **how far the branch stands from its upstream comes free from a call the
/// app already makes**. That is a different comparison from `rev-list --count`
/// against the *base* branch, which is what `AheadBehind` measures and which
/// stays exactly where it was.
///
/// `branch.ab` is absent, and the distance therefore **null rather than zero**,
/// in the two cases where git does not know it: a branch with no upstream, and
/// an upstream that has gone from the remote — v1's `[gone]`. Level with an
/// upstream is `+0 -0`, stated, which is the case v1 expressed by saying
/// nothing.
///
/// ## The two records v1 does not have, and both are silent when missed
///
/// * **`2` — a rename or a copy.** Its last field is `<path>\t<origPath>`, two
///   paths on one line separated by a **tab**, which v1 never writes. Splitting
///   the line on whitespace merges them into a single nonsense path and
///   undercounts the dirty files by one per rename.
/// * **`u` — an unmerged path.** v1 reported a conflict as an ordinary `UU`
///   entry; v2 gives it its own record type. A parse that handles only `1`, `2`
///   and `?` drops conflicted files out of the listing altogether — a row that
///   is mid-merge would report itself clean.
///
/// The status letters themselves are v1's, with one substitution: v2 writes `.`
/// where v1 wrote a space. So `1 .M` is modified-but-unstaged and `1 M.` is
/// staged, and an unmerged `u UU` still reads as "staged and unstaged with an
/// unrecognised code", exactly as `UU` did — which is what the two callers that
/// render [FileChangeType.unknown] as *"changed (unrecognised git status)"*
/// have always shown for a conflict.
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
    case 'u':
      final fields = _v2Fields(line, 11);
      return fields == null ? null : _v2Change(fields[1], fields[10]);
    // ? <path>
    case '?':
      if (line.length < 3) return null;
      return FileChange(
        path: line.substring(2),
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
/// `.` is v2's "unmodified", where v1 wrote a space; everything else is the
/// same letter v1 used, so [_typeOf] is shared and a conflict still reads the
/// way it always did.
FileChange _v2Change(String xy, String path, {String? originalPath}) {
  final x = xy.isNotEmpty ? xy[0] : '.';
  final y = xy.length > 1 ? xy[1] : '.';
  return FileChange(
    path: path,
    originalPath: originalPath,
    type: _typeOf(x != '.' ? x : y),
    staged: x != '.',
    unstaged: y != '.',
  );
}
