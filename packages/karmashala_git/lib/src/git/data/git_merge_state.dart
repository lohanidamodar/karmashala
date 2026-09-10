import 'git_dir.dart';
import 'git_files.dart';

/// **Whether a merge is half-done in the working tree**, read off `.git`
/// instead of asked of git.
///
/// `.git/MERGE_HEAD` is what `git merge --abort` itself looks for, and reading it
/// costs no `CreateProcessW` — which is why the Abort-merge button can ask at all.
///
/// **Null is "could not tell", never false**: an SSH checkout has no path this
/// process can open, and a dead `\\wsl.localhost` share stats like an empty folder.
class GitMergeStateReader {
  GitMergeStateReader({required this.files, required this.hostPathOf});

  final GitFiles files;

  /// How a path inside the repository's environment is spelled for this
  /// process. Null for a filesystem this process cannot open at all.
  final HostPathOrNone hostPathOf;

  /// Whether the working tree at [checkout] has a merge in progress.
  ///
  /// One `stat` for a checkout in a merge, two for a clean one, four for a
  /// worktree — whose `MERGE_HEAD` is in its own git directory, not the shared one.
  Future<bool?> read(String checkout) async {
    final host = hostPathOf(checkout);
    if (host == null) return null;
    final context = gitPathContextFor(host);

    final dotGit = context.join(host, '.git');
    if (await files.typeOf(context.join(dotGit, 'MERGE_HEAD')) ==
        PathEntry.file) {
      return true;
    }
    // Nothing there, and now the question is *why*: `PathEntry.none` cannot tell
    // an absent `.git` from a share that stopped answering.
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
