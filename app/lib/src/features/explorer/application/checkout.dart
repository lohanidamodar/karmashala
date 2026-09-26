import 'package:agent_cli/process.dart';

/// A working tree, identified by **where it is** rather than by how a path to
/// it is spelled: three sources disagree about separators and case, and keying
/// on the raw [EnvironmentPath] ran `git status` once per spelling.
class Checkout {
  const Checkout(this.path, {this.repository});

  /// The path as the caller wrote it. This, not the canonical form, is what
  /// runs — lower-casing a WSL path would point at nothing.
  final EnvironmentPath path;

  /// The repository this working tree belongs to, when the caller knows it.
  /// Deliberately outside [==] and [hashCode], like the spelling of [path], so
  /// `Checkout(wt)` and `Checkout(wt, repository: r)` stay one entry.
  final EnvironmentPath? repository;

  /// The repository half of this checkout, as its own key: every worktree of
  /// one clone maps onto one entry, and it carries no [repository] of its own.
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
/// dropped, and case folded **only for an unambiguously Windows path**. A POSIX
/// filesystem is case-sensitive, so folding everything merges real directories.
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

/// Whether [child] is [parent] or sits beneath it, within one environment only.
/// Deliberately not translating: the tree must never silently move a session
/// between environments.
bool isUnder(EnvironmentPath parent, EnvironmentPath child) {
  if (parent.environmentId != child.environmentId) return false;
  final p = canonicalPathKey(parent.path);
  final c = canonicalPathKey(child.path);
  return c == p || c.startsWith('$p/');
}

/// How many segments deep a path is — used to pick the *deepest* row a
/// directory sits under, so a nested repository wins over the hub above it.
int pathDepth(EnvironmentPath path) =>
    canonicalPathKey(path.path).split('/').where((s) => s.isNotEmpty).length;

/// [child] written relative to [parent] — `projects/karmashala-app` — or null
/// when they are the same place or [child] is not under [parent]. Separators
/// come out as forward slashes: a relative path is read, not executed.
String? relativeSubPath(EnvironmentPath parent, EnvironmentPath child) {
  if (!isUnder(parent, child)) return null;
  final p = canonicalPathKey(parent.path);
  final full = child.path.replaceAll('\\', '/');
  if (canonicalPathKey(child.path) == p) return null;
  return full.substring(p.length + 1);
}
