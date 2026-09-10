import 'package:path/path.dart' as p;

import 'git_files.dart';

/// How to join onto [host].
///
/// Read off the *host* path's own shape, not the environment kind: paths inside
/// WSL are POSIX but the host spelling of one is a `\\wsl.localhost\…` UNC, and
/// joining that with the POSIX context builds something no `File` can open.
p.Context gitPathContextFor(String host) =>
    RegExp(r'^[A-Za-z]:').hasMatch(host) || host.startsWith(r'\\')
    ? p.windows
    : p.posix;

/// The `gitdir:` a worktree's or submodule's `.git` file names, in **host**
/// spelling, or null when [text] is not such a file.
///
/// The path inside is written the way the repository's own environment spells it,
/// so it is translated on the way out; git also accepts a *relative* gitdir since
/// 2.48, relative to the working tree. `GitOriginReader` and `GitMergeStateReader`
/// share this one rule so they cannot describe a worktree differently.
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
