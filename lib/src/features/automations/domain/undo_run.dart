/// What undoing an automation's run is allowed to take back.
///
/// **Asymmetric on purpose.** Restoring files is always offered: the run's base
/// checkpoint holds every byte as it stood before the agent touched anything,
/// and putting them back changes nothing anyone else can see. Dropping the
/// commits the run made is a history rewrite, so it is opt-in and **refused
/// outright once any of them exists on a remote**.
///
/// Pure, so the button's tooltip and the write path's assertion read the same
/// rule — the reason shown on hover is the one the write path would have
/// thrown.
library;

/// One commit a run left on the branch. The short form is for display only.
class RunCommit {
  const RunCommit({required this.sha, required this.subject});

  final String sha;
  final String subject;

  String get shortSha => sha.length <= 7 ? sha : sha.substring(0, 7);
}

/// What a run left behind, as git answers it now.
class RunCommits {
  const RunCommits({
    required this.baseSha,
    required this.commits,
    required this.published,
  });

  /// Nothing was measured. Distinct from "measured, and there is nothing".
  static const unread = RunCommits(baseSha: null, commits: [], published: null);

  /// Where the branch stood when the run started, from the base checkpoint's
  /// recorded `HEAD`. Null when there is nothing safe to reset to — no
  /// checkpoint, a repository with no commits yet, or a history that has moved
  /// and no longer contains it.
  final String? baseSha;

  /// Commits between the run's base and HEAD, newest first.
  final List<RunCommit> commits;

  /// How many of them a remote-tracking branch already holds, or **null when
  /// git could not be asked**. Never read as zero: "nothing outside this
  /// machine has these" and "we could not find out" are the two answers this
  /// rule turns on, and collapsing them drops published history.
  final int? published;
}

/// Why the commits cannot be dropped, or `null` when they can.
///
/// **Never a reason to block the file-level undo** — that path stands on its
/// own and is always offered.
String? undoCommitsRefusal(RunCommits summary) {
  if (summary.published == null && summary.commits.isEmpty) {
    return 'What this run left on the branch has not been read, so nothing is '
        'dropped. Nothing is undone on a reading Karmashala could not take.';
  }
  if (summary.commits.isEmpty) return 'This run made no commits.';
  final published = summary.published;
  if (published == null) {
    return 'Git could not be asked which remote branches hold these commits, '
        'so whether dropping them would rewrite published history is not '
        'recorded. Nothing is dropped on a reading Karmashala could not take.';
  }
  if (published > 0) {
    return published == summary.commits.length
        ? 'These commits are already on a remote. Dropping them would rewrite '
              'published history — revert them instead. (Remote branches are '
              'read as of the last fetch, so `git fetch` first if they were '
              'pushed from somewhere else.)'
        : '$published of these ${summary.commits.length} commits are already '
              'on a remote. Dropping them would rewrite published history — '
              'revert them instead.';
  }
  if (summary.baseSha == null || summary.baseSha!.isEmpty) {
    return 'The branch has moved since this run started, so there is no commit '
        'to reset back to.';
  }
  return null;
}

/// Whether the commits may be dropped.
bool canUndoRunCommits(RunCommits summary) => undoCommitsRefusal(summary) == null;

/// The checkbox's label. The count is the whole point, so it leads.
String undoCommitsLabel(RunCommits summary) {
  final n = summary.commits.length;
  if (n == 1) return 'Also drop the commit this run made';
  return 'Also drop the $n commits this run made';
}

/// What restoring the files says it will do. Always offered, so it never has a
/// refusal of its own — only a description.
String undoFilesLabel(RunCommits summary) =>
    'Put the files back as they stood before this run started';
