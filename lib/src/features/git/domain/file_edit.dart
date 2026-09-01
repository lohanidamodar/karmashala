/// What an agent's file-writing tool did to one path.
///
/// Deliberately smaller than [FileChangeType]: git reports what a *tree* looks
/// like and has to describe renames and copies; an agent's write tool only ever
/// creates, rewrites or removes one file, and a kind the readers can never
/// produce would be a branch nothing tests.
enum FileEditKind {
  created,
  modified,
  deleted;

  /// The word shown beside the path, so the change type is never carried by
  /// colour alone (CLAUDE.md §5, accessibility).
  String get label => switch (this) {
    FileEditKind.created => 'Created',
    FileEditKind.modified => 'Modified',
    FileEditKind.deleted => 'Deleted',
  };
}

/// One file an agent wrote, as **the agent's own record of the write**
/// describes it.
///
/// ## Why this is not read off the disk
///
/// Every field here comes out of the transcript the CLI wrote for itself, and
/// nothing in this feature opens the file. Three reasons, in order of how much
/// they matter:
///
/// 1. **The disk has moved on.** A turn edits a file five times; the working
///    tree only remembers the fifth. Diffing edit #2 against what is there now
///    shows a change nobody made.
/// 2. **The file may not be reachable.** A session can run in WSL or over SSH,
///    where the path in the record does not resolve in this process.
/// 3. **The UI isolate must not read files.** This app's database bindings are
///    synchronous and its window shares that isolate; a `readAsStringSync` per
///    visible edit is a frozen window.
///
/// The record is also *better* evidence than the file: for Claude Code and
/// Codex it already contains a computed patch ([recordedDiff]), so the common
/// case costs no diffing at all.
class FileEditRecord {
  const FileEditRecord({
    required this.path,
    required this.kind,
    this.toolName = '',
    this.oldText,
    this.newText,
    this.recordedDiff,
    this.renamedTo,
  });

  /// The path as the agent named it — usually absolute, and in the session's
  /// own environment, which may not be this one.
  final String path;

  final FileEditKind kind;

  /// The tool that made the write (`Edit`, `Write`, `MultiEdit`,
  /// `apply_patch`), for a caller that wants to say how it happened. Empty when
  /// the record does not name one.
  final String toolName;

  /// The text before the write. For a Claude `Edit` this is the *fragment* that
  /// was replaced, not the whole file — see [isFragment].
  final String? oldText;

  /// The text after the write, under the same caveat as [oldText].
  final String? newText;

  /// A unified diff the agent computed itself, when its record kept one.
  ///
  /// Hunk bodies only (`@@ … @@` plus ` `/`+`/`-` lines) — there is no
  /// `diff --git` header, because neither CLI records one and inventing one
  /// would put a repository-relative path we do not have into the output.
  final String? recordedDiff;

  /// Where the file moved to, for the one tool that can rename (Codex's
  /// `apply_patch` update with a `move_path`); otherwise `null`.
  final String? renamedTo;

  /// Whether [oldText]/[newText] are excerpts rather than whole files.
  ///
  /// True exactly when there is no recorded patch to place them: a fragment has
  /// no line numbers in the file, so a diff built from it must not print a
  /// `@@ -a,b +c,d @@` header claiming it has.
  bool get isFragment =>
      recordedDiff == null && kind == FileEditKind.modified;

  @override
  bool operator ==(Object other) =>
      other is FileEditRecord &&
      other.path == path &&
      other.kind == kind &&
      other.toolName == toolName &&
      other.oldText == oldText &&
      other.newText == newText &&
      other.recordedDiff == recordedDiff &&
      other.renamedTo == renamedTo;

  /// Hashed on **lengths**, not contents: the texts here run to hundreds of
  /// kilobytes and this type is a cache key, so hashing them would walk the
  /// whole file on every lookup. Equality still compares them in full; a
  /// collision costs one string compare, hashing costs one per lookup.
  @override
  int get hashCode => Object.hash(
    path,
    kind,
    toolName,
    oldText?.length,
    newText?.length,
    recordedDiff?.length,
  );

  @override
  String toString() => 'FileEditRecord(${kind.name} $path)';
}
