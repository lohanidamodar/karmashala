import '../data/git_diff_parsing.dart' show unquoteGitPath;

/// What `git status --porcelain=v1 --ignored` says a working tree holds that no
/// commit does.
class WorktreeContents {
  const WorktreeContents({this.changes = const [], this.ignored = const []});

  /// Modified, staged and untracked paths — work that exists nowhere else.
  final List<String> changes;

  /// Ignored paths, directories collapsed the way git reports them (`build/`).
  final List<String> ignored;
}

/// Reads [porcelain] from `git status --porcelain=v1 --ignored`.
WorktreeContents parseWorktreeContents(String porcelain) {
  final changes = <String>[];
  final ignored = <String>[];
  for (final raw in porcelain.split(RegExp(r'[\r\n]'))) {
    if (raw.length < 4) continue;
    final path = unquoteGitPath(raw.substring(3).trim());
    if (raw.startsWith('!! ')) {
      ignored.add(path);
    } else {
      changes.add(path);
    }
  }
  return WorktreeContents(changes: changes, ignored: ignored);
}

/// One reflog line: when the ref moved, and git's words for why.
class ReflogEntry {
  const ReflogEntry({required this.at, required this.subject});

  final DateTime at;

  /// `commit: fix the thing`, `branch: Created from HEAD`, or empty — which is
  /// what `git worktree add` writes for the worktree's first HEAD.
  final String subject;

  /// Whether this move was a commit made on the ref, rather than the ref being
  /// created, checked out, reset or fast-forwarded to someone else's work.
  bool get isOwnCommit =>
      subject.startsWith('commit') ||
      subject.startsWith('cherry-pick') ||
      subject.startsWith('revert');

  @override
  String toString() => 'ReflogEntry($at, $subject)';
}

/// Reads `git reflog show --date=unix --format=%gd%x09%gs`, whose selector
/// carries the time: `HEAD@{1789990666}<TAB>commit: c1`.
List<ReflogEntry> parseReflog(String output) {
  final entries = <ReflogEntry>[];
  final selector = RegExp(r'@\{(\d+)\}');
  for (final line in output.split(RegExp(r'[\r\n]+'))) {
    if (line.trim().isEmpty) continue;
    final tab = line.indexOf('\t');
    final head = tab < 0 ? line : line.substring(0, tab);
    final match = selector.firstMatch(head);
    final seconds = match == null ? null : int.tryParse(match.group(1)!);
    if (seconds == null) continue;
    entries.add(
      ReflogEntry(
        at: DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true),
        subject: tab < 0 ? '' : line.substring(tab + 1).trim(),
      ),
    );
  }
  return entries;
}
