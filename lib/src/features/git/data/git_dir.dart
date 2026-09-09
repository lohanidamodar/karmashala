import 'package:path/path.dart' as p;

import 'git_files.dart';

/// How to join onto [host].
///
/// Read off the *host* path's own shape rather than off the environment kind,
/// because the two disagree exactly where it matters: paths inside WSL are
/// POSIX, but the host spelling of one is the `\\wsl.localhost\…` UNC form,
/// which is a Windows path. Joining that with the POSIX context would build
/// something no `File` can open — the same trap `storePathContextFor`
/// documents for a store home.
p.Context gitPathContextFor(String host) =>
    RegExp(r'^[A-Za-z]:').hasMatch(host) || host.startsWith(r'\\')
    ? p.windows
    : p.posix;

/// The `gitdir:` a worktree's or submodule's `.git` file names, in **host**
/// spelling, or null when [text] is not such a file.
///
/// The path inside it is written the way the repository's own environment
/// spells it, so it is translated on the way out — a WSL worktree names
/// `/home/me/repo/.git/worktrees/wt-1`, which this process opens as a
/// `\\wsl.localhost\…` share. Git also accepts a *relative* gitdir (what
/// `--relative-paths` writes since 2.48), which is relative to the working
/// tree.
///
/// One rule, shared: `GitOriginReader` walks this to find `.git/config` and
/// `GitMergeStateReader` walks it to find `MERGE_HEAD`, and a worktree the two
/// resolved differently would be a repository they described differently.
String? gitDirNamedIn(
  String? text, {
  required String host,
  required p.Context context,
  required HostPathOrNone hostPathOf,
}) {
  if (text == null) return null;
  final line = text
      .split(RegExp(r'[\r\n]'))
      .map((l) => l.trim())
      .firstWhere((l) => l.isNotEmpty, orElse: () => '');
  if (!line.startsWith('gitdir:')) return null;
  final named = line.substring('gitdir:'.length).trim();
  if (named.isEmpty) return null;
  // Normalised, because a relative gitdir is written as `../../app/.git/…` and
  // the `..` segments have to be resolved before anything opens it.
  if (!_isAbsolute(named)) return context.normalize(context.join(host, named));
  return hostPathOf(named);
}

bool _isAbsolute(String path) =>
    path.startsWith('/') ||
    path.startsWith(r'\\') ||
    RegExp(r'^[A-Za-z]:').hasMatch(path);
