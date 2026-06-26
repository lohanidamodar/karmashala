/// The role of a line within a unified diff, for display.
enum DiffLineKind {
  /// File/diff headers (`diff --git`, `index`, `---`, `+++`).
  meta,

  /// Hunk header (`@@ -a,b +c,d @@`).
  hunk,

  /// An added line (`+`).
  added,

  /// A removed line (`-`).
  removed,

  /// An unchanged context line.
  context,
}

/// One line of a parsed unified diff.
class DiffLine {
  const DiffLine(this.kind, this.text);
  final DiffLineKind kind;
  final String text;

  @override
  bool operator ==(Object other) =>
      other is DiffLine && other.kind == kind && other.text == text;

  @override
  int get hashCode => Object.hash(kind, text);

  @override
  String toString() => 'DiffLine($kind, $text)';
}
