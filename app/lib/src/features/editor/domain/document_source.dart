/// Where an editor document's bytes come from: one environment's files behind
/// the handful of verbs an editor needs, so this machine, a WSL distribution
/// and an SSH host are the same thing to the buffers. See
/// docs/document-sources.md.
library;

import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'source_document.dart';

/// What one stat saw. [version] is opaque to callers beyond
/// [FileStamp.matches]; null exactly when nothing is there.
class DocumentStat {
  const DocumentStat.absent()
    : exists = false,
      isDirectory = false,
      size = 0,
      version = null;

  const DocumentStat({
    required this.isDirectory,
    required this.size,
    required FileStamp this.version,
  }) : exists = true;

  final bool exists;
  final bool isDirectory;
  final int size;
  final FileStamp? version;
}

/// What a write expects to find, so it can refuse rather than overwrite a
/// change it has not seen.
sealed class WriteExpectation {
  const WriteExpectation();

  /// Overwrite whatever is there — the reader chose to.
  const factory WriteExpectation.any() = _Any;

  /// Nothing may be there: a deleted file put back by Save.
  const factory WriteExpectation.absent() = _Absent;

  /// The file must still be [version].
  const factory WriteExpectation.version(FileStamp version) = _Version;

  /// Whether a file currently at [current] (null: absent) may be replaced.
  bool accepts(FileStamp? current);
}

final class _Any extends WriteExpectation {
  const _Any();

  @override
  bool accepts(FileStamp? current) => true;
}

final class _Absent extends WriteExpectation {
  const _Absent();

  @override
  bool accepts(FileStamp? current) => current == null;
}

final class _Version extends WriteExpectation {
  const _Version(this.version);

  final FileStamp version;

  @override
  bool accepts(FileStamp? current) => version.matches(current);
}

/// What an environment can do, asked rather than assumed.
class DocumentSourceCapabilities {
  const DocumentSourceCapabilities({
    required this.atomicReplace,
    required this.cheapStat,
    this.readOnly = false,
    this.changeHints = true,
  });

  /// Nothing may be written here; a save is refused before it is tried.
  final bool readOnly;

  /// A write lands whole or not at all (temp file + rename). Where it is false
  /// the file is rewritten in place, still checked against its version first.
  final bool atomicReplace;

  /// A stat costs a syscall, not a round trip. Where it is false a check may
  /// take seconds, so callers keep one in flight per file.
  final bool cheapStat;

  /// Agent hooks may name files here, so a hook can prompt a check.
  final bool changeHints;
}

/// The link to the environment is down: nothing was learned about the file.
/// Distinct from a refusal, because a buffer must neither be marked changed
/// nor lose its text over a dropped connection.
class DocumentUnreachableException implements Exception {
  const DocumentUnreachableException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A write refused because the file is not the version it expected.
class DocumentStaleException implements Exception {
  const DocumentStaleException(this.current);

  /// What is there now; null when the file is gone.
  final FileStamp? current;

  @override
  String toString() => current == null
      ? 'The file is no longer on disk.'
      : 'The file changed on disk.';
}

/// One environment's files. Paths are in that environment's own spelling.
abstract class DocumentSource {
  String get environmentId;

  /// How paths are spelled here.
  p.Context get pathContext;

  DocumentSourceCapabilities get capabilities;

  /// Throws [DocumentUnreachableException] when the environment did not
  /// answer; anything else is a stat of what is there.
  Future<DocumentStat> stat(String path);

  /// The first [length] bytes, or the whole file when null.
  Future<Uint8List> read(String path, {int? length});

  /// Replaces [path] with [bytes] if [expect] accepts what is there, creating
  /// it when [expect] allows absence. Answers the version now on disk. Throws
  /// [DocumentStaleException] when refused, [DocumentUnreachableException]
  /// when the environment dropped, and a readable [DocumentSourceException]
  /// otherwise.
  Future<FileStamp> write(
    String path,
    Uint8List bytes, {
    required WriteExpectation expect,
  });

  /// The same file spelled for `dart:io` on this desktop, or null when it can
  /// only be reached by asking its environment.
  String? hostPathOf(String path);

  Future<void> close();
}

/// A read or write the environment refused, in words to show.
class DocumentSourceException implements Exception {
  const DocumentSourceException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Finds the source for an environment; null when this build cannot open files
/// there.
abstract class DocumentSourceResolver {
  DocumentSource? sourceFor(String environmentId);
}
