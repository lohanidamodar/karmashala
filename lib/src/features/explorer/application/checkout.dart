import '../../environments/domain/environment_path.dart';

/// A working tree, identified by **where it is** rather than by how a path to
/// it happens to be spelled.
///
/// The Explorer learns about the same checkout from three sources that disagree
/// about spelling: the `repositories` table (`C:\src\demo`), `Session.worktree`
/// (built with `p.windows.join`, so backslashes), and `git worktree list
/// --porcelain`, which reports forward slashes on Windows. Keying a provider on
/// the raw [EnvironmentPath] therefore ran `git status` once **per spelling** —
/// the row and the card under it describing one directory with two processes.
///
/// So the key compares the way the filesystem does, and the value keeps the
/// original spelling: whichever one reached the provider first is the one git is
/// handed, and both are valid paths to the same tree.
class Checkout {
  const Checkout(this.path);

  /// The path as the caller wrote it. This, not the canonical form, is what
  /// runs — lower-casing a WSL path would point at nothing.
  final EnvironmentPath path;

  String get _key => canonicalPathKey(path.path);

  @override
  bool operator ==(Object other) =>
      other is Checkout &&
      other.path.environmentId == path.environmentId &&
      other._key == _key;

  @override
  int get hashCode => Object.hash(path.environmentId, _key);

  @override
  String toString() => 'Checkout(${path.environmentId}: ${path.path})';
}

/// The comparison form of [path]: separators unified, trailing separator
/// dropped, and case folded **only for a path that is unambiguously Windows**
/// (a drive letter or a UNC root). A POSIX filesystem is case-sensitive and
/// `/home/A` is not `/home/a`, so folding everything would merge two real
/// directories into one row.
String canonicalPathKey(String path) {
  var value = path.replaceAll('\\', '/');
  while (value.length > 1 && value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  return _looksWindows(path) ? value.toLowerCase() : value;
}

/// Whether two paths in the same environment name the same location.
bool samePath(String a, String b) => canonicalPathKey(a) == canonicalPathKey(b);

bool _looksWindows(String path) =>
    RegExp(r'^[A-Za-z]:').hasMatch(path) || path.startsWith(r'\\');

/// Whether [child] is [parent] or sits beneath it, comparing within one
/// environment only.
///
/// Deliberately not translating: a `/home/me/app` in Ubuntu is not under
/// `C:\src` in Windows however the strings look, and the tree must never
/// silently move a session between environments. Callers that genuinely need to
/// compare across two environments translate first, with both in hand.
bool isUnder(EnvironmentPath parent, EnvironmentPath child) {
  if (parent.environmentId != child.environmentId) return false;
  final p = canonicalPathKey(parent.path);
  final c = canonicalPathKey(child.path);
  return c == p || c.startsWith('$p/');
}

/// How many segments deep a path is. Used to pick the **deepest** row a
/// directory sits under, so a session in a nested repository nests under that
/// repository rather than under the hub that contains it.
int pathDepth(EnvironmentPath path) =>
    canonicalPathKey(path.path).split('/').where((s) => s.isNotEmpty).length;

/// [child] written relative to [parent] — `projects/karmashala-app` — or null
/// when they are the same place or [child] is not under [parent].
///
/// Preserves the original spelling's separators as forward slashes, which is
/// what a row subtitle wants: a relative path is being read, not executed.
String? relativeSubPath(EnvironmentPath parent, EnvironmentPath child) {
  if (!isUnder(parent, child)) return null;
  final p = canonicalPathKey(parent.path);
  final full = child.path.replaceAll('\\', '/');
  if (canonicalPathKey(child.path) == p) return null;
  return full.substring(p.length + 1);
}
