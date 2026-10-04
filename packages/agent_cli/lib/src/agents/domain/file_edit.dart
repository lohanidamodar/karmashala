/// What an agent's file-writing tool did to one path.
///
/// Smaller than a working-tree change type on purpose: an agent's write tool only ever
/// creates, rewrites or removes one file.
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
/// **Nothing here opens the file.** A turn edits a file five times and the disk
/// only remembers the fifth; the path may be in WSL or over SSH; and a
/// `readAsStringSync` per visible edit on the UI isolate is a frozen window. The
/// record is better evidence anyway — it usually carries a computed patch.
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
  /// Hunk bodies only: neither CLI records a `diff --git` header, and inventing
  /// one would put a repository-relative path we do not have into the output.
  final String? recordedDiff;

  /// Where the file moved to, for the one tool that can rename (Codex's
  /// `apply_patch` update with a `move_path`); otherwise `null`.
  final String? renamedTo;

  /// Whether [oldText]/[newText] are excerpts rather than whole files.
  ///
  /// True exactly when there is no recorded patch to place them: a fragment has
  /// no line numbers, so a diff from it must not print a `@@ -a,b +c,d @@` header.
  bool get isFragment => recordedDiff == null && kind == FileEditKind.modified;

  /// The wire form a transcript page carries; absent fields are left out.
  Map<String, Object?> toJson() => {
    'path': path,
    'kind': kind.name,
    if (toolName.isNotEmpty) 'toolName': toolName,
    'oldText': ?oldText,
    'newText': ?newText,
    'recordedDiff': ?recordedDiff,
    'renamedTo': ?renamedTo,
  };

  /// Null when `path` is missing; an unknown `kind` reads as modified.
  static FileEditRecord? fromJson(Map<String, Object?> json) {
    final path = json['path'];
    if (path is! String || path.isEmpty) return null;
    String? text(String key) => switch (json[key]) {
      final String value => value,
      _ => null,
    };
    return FileEditRecord(
      path: path,
      kind:
          FileEditKind.values.asNameMap()[json['kind']] ??
          FileEditKind.modified,
      toolName: text('toolName') ?? '',
      oldText: text('oldText'),
      newText: text('newText'),
      recordedDiff: text('recordedDiff'),
      renamedTo: text('renamedTo'),
    );
  }

  FileEditRecord copyWith({
    String? oldText,
    String? newText,
    String? recordedDiff,
  }) => FileEditRecord(
    path: path,
    kind: kind,
    toolName: toolName,
    oldText: oldText ?? this.oldText,
    newText: newText ?? this.newText,
    recordedDiff: recordedDiff ?? this.recordedDiff,
    renamedTo: renamedTo,
  );

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

  /// Hashed on **lengths**, not contents: these texts run to hundreds of kilobytes
  /// and this type is a cache key. Equality still compares in full — a collision
  /// costs one string compare, hashing would cost one walk per lookup.
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
