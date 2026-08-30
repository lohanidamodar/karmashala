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

/// Parses `git status --porcelain=v1 --branch`.
///
/// The first line is git's branch header and is **not** a file: reading it as
/// one would add a change called `## work...origin/work` to every listing. The
/// header carries the branch, its upstream and the divergence between them:
///
/// ```txt
/// ## work...origin/work [ahead 2, behind 1]
/// ## work                       (no upstream)
/// ## HEAD (no branch)           (detached)
/// ## No commits yet on main
/// ## main...origin/main [gone]  (upstream deleted on the remote)
/// ```
WorkingTreeStatus parseGitStatusBranch(String porcelain) {
  final lines = porcelain.split(RegExp(r'[\r\n]'));
  final header = lines.firstWhere(
    (line) => line.startsWith('## '),
    orElse: () => '',
  );
  final body = [
    for (final line in lines)
      if (!line.startsWith('## ')) line,
  ].join('\n');

  if (header.isEmpty) {
    return WorkingTreeStatus(changes: parseGitStatus(body));
  }

  var rest = header.substring(3).trim();
  String? branch;
  String? upstream;
  int? ahead;
  int? behind;

  final bracket = rest.indexOf(' [');
  var divergence = '';
  if (bracket >= 0 && rest.endsWith(']')) {
    divergence = rest.substring(bracket + 2, rest.length - 1);
    rest = rest.substring(0, bracket);
  }

  if (rest == 'HEAD (no branch)') {
    branch = null;
  } else if (rest.startsWith('No commits yet on ')) {
    branch = rest.substring('No commits yet on '.length).trim();
  } else {
    final split = rest.indexOf('...');
    if (split < 0) {
      branch = rest.trim();
    } else {
      branch = rest.substring(0, split).trim();
      upstream = rest.substring(split + 3).trim();
      // An upstream that still exists is level unless git says otherwise; an
      // upstream reported `gone` has no distance to report at all.
      ahead = 0;
      behind = 0;
    }
  }

  if (divergence == 'gone') {
    ahead = null;
    behind = null;
  } else if (divergence.isNotEmpty) {
    for (final part in divergence.split(',')) {
      final words = part.trim().split(RegExp(r'\s+'));
      if (words.length != 2) continue;
      final count = int.tryParse(words[1]);
      if (count == null) continue;
      if (words[0] == 'ahead') ahead = count;
      if (words[0] == 'behind') behind = count;
    }
  }

  return WorkingTreeStatus(
    branch: (branch?.isEmpty ?? true) ? null : branch,
    upstream: (upstream?.isEmpty ?? true) ? null : upstream,
    aheadOfUpstream: ahead,
    behindUpstream: behind,
    changes: parseGitStatus(body),
  );
}
