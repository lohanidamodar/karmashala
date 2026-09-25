/// The kinds of evidence a run keeps on disk.
enum VerificationArtifactKind {
  screenshot('Screenshot', 'png'),
  elementCapture('Element', 'md'),
  consoleErrors('Console errors', 'txt'),
  networkFailures('Failed requests', 'txt'),
  logcat('Logcat', 'txt'),
  uiTree('UI tree', 'txt'),
  report('Report', 'md'),
  other('File', 'txt');

  const VerificationArtifactKind(this.label, this.extension);

  final String label;
  final String extension;

  /// Whether the file is an image, and so belongs in a report as a picture and
  /// in an MCP result as an image block.
  bool get isImage => this == VerificationArtifactKind.screenshot;

  static VerificationArtifactKind parse(String? value) {
    for (final kind in values) {
      if (kind.name == value) return kind;
    }
    return VerificationArtifactKind.other;
  }
}

/// A file captured during a run. The bytes are never in SQLite: the row records
/// where the file is, and [relativePath] is relative to the run's own directory
/// so the exported image links work wherever the folder is copied to.
class VerificationArtifact {
  const VerificationArtifact({
    required this.id,
    required this.runId,
    required this.kind,
    required this.label,
    required this.relativePath,
    required this.byteSize,
    required this.at,
    this.stepOrdinal,
  });

  final String id;
  final String runId;
  final VerificationArtifactKind kind;

  /// What this file is, in the user's terms — "Element `#submit`", "Console
  /// errors during the run".
  final String label;

  final String relativePath;
  final int byteSize;
  final DateTime at;

  /// The step this came out of, or null for the ones collected when the run is
  /// finished.
  final int? stepOrdinal;

  String get sizeLabel => byteSize < 1024
      ? '$byteSize B'
      : '${(byteSize / 1024).toStringAsFixed(1)} KB';
}
