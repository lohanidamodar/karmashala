import 'git_dir.dart';
import 'git_files.dart';

/// **Whether a merge is half-done in the working tree**, read off `.git`
/// instead of asked of git.
///
/// `.git/MERGE_HEAD` is the file `git merge` writes when it stops without
/// committing and deletes when the merge finishes or is aborted — it is what
/// `git merge --abort` itself looks for. Reading it costs no `CreateProcessW`,
/// which is the whole reason this exists: the Abort-merge button's own doc
/// refused to ask the question because asking it meant a process on every poll.
///
/// **Null is "could not tell", never false.** A repository on an SSH host has
/// no path this process can open and a dead `\\wsl.localhost` share answers a
/// stat exactly like an empty folder, so the reading admits the gap and the
/// caller falls back to what the listing already says (§19).
class GitMergeStateReader {
  GitMergeStateReader({required this.files, required this.hostPathOf});

  final GitFiles files;

  /// How a path inside the repository's environment is spelled for this
  /// process. Null for a filesystem this process cannot open at all.
  final HostPathOrNone hostPathOf;

  /// Whether the working tree at [checkout] has a merge in progress.
  ///
  /// One `stat` for a checkout in a merge, two for an ordinary clean one, and
  /// four for a worktree — whose `.git` is a *file* naming the real git
  /// directory, and whose `MERGE_HEAD` lives in that directory rather than in
  /// the one its siblings share.
  Future<bool?> read(String checkout) async {
    final host = hostPathOf(checkout);
    if (host == null) return null;
    final context = gitPathContextFor(host);

    final dotGit = context.join(host, '.git');
    if (await files.typeOf(context.join(dotGit, 'MERGE_HEAD')) ==
        PathEntry.file) {
      return true;
    }
    // Nothing there, and now the question is *why*: an ordinary `.git`
    // directory with no merge in it is a real `false`, and anything else is a
    // gap. `PathEntry.none` cannot tell an absent `.git` from a share that
    // stopped answering, which is exactly the pair this must not collapse.
    final entry = await files.typeOf(dotGit);
    if (entry == PathEntry.directory) return false;
    if (entry == PathEntry.none) return null;

    final gitDir = gitDirNamedIn(
      await files.readString(dotGit),
      host: host,
      context: context,
      hostPathOf: hostPathOf,
    );
    if (gitDir == null) return null;
    return await files.typeOf(context.join(gitDir, 'MERGE_HEAD')) ==
        PathEntry.file;
  }
}
