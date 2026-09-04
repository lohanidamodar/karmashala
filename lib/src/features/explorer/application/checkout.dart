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
  const Checkout(this.path, {this.repository});

  /// The path as the caller wrote it. This, not the canonical form, is what
  /// runs — lower-casing a WSL path would point at nothing.
  final EnvironmentPath path;

  /// The repository this working tree belongs to, when the caller knows it,
  /// and null when it does not.
  ///
  /// **Deliberately outside [==] and [hashCode]**, exactly like the spelling
  /// of [path] above: `Checkout(wt)` and `Checkout(wt, repository: repo)` are
  /// the same working tree and must stay one provider entry, or a row and the
  /// card under it would run git twice for one directory again. Whichever
  /// reached the provider first is the one whose answer is used — the rule the
  /// class doc already states for the path.
  ///
  /// It exists because two facts a delivery reading needs — `origin`'s URL and
  /// `origin/HEAD` — belong to the **repository** and not to the working tree,
  /// so every worktree of one clone has the same answer. The app knows the
  /// pairing from the session row that made the worktree; git would only know
  /// it after a process or a read of `.git`. See [forRepository].
  ///
  /// A caller that omits it is not wrong, only less thrifty: the working tree
  /// is then treated as its own repository, which git answers identically —
  /// remote refs are shared by every worktree — for the price of one extra
  /// reading. It is never a wrong answer, only a repeated one.
  final EnvironmentPath? repository;

  /// The repository half of this checkout, as its own key.
  ///
  /// This is what a repository-level provider is keyed by: every worktree of
  /// one clone, and the clone itself, map onto one entry. The result carries
  /// no [repository] of its own — a repository is its own repository, and a
  /// second spelling of that would be a second key.
  Checkout forRepository() {
    final repo = repository;
    return repo == null ? this : Checkout(repo);
  }

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
