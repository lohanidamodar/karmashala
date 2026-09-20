/// One browsable filesystem behind the verbs a file browser needs, so this
/// machine's disk and a host's over SFTP are the same thing to whatever draws
/// them. Every path is an [EnvironmentPath]: a name on its own has no machine,
/// and the two sides of a copy are always on different ones.
library;

import 'package:agent_cli/process.dart';
import 'package:path/path.dart' as p;

/// What one entry in a listing is.
enum FileEntryKind { file, directory, symlink, other }

/// One entry in a directory, as both sides report it.
class FileEntry {
  const FileEntry({
    required this.name,
    required this.path,
    required this.kind,
    this.sizeBytes,
    this.modifiedAt,
  });

  final String name;
  final EnvironmentPath path;
  final FileEntryKind kind;

  /// Null when the filesystem did not say — never 0 as a stand-in.
  final int? sizeBytes;
  final DateTime? modifiedAt;

  bool get isDirectory => kind == FileEntryKind.directory;

  @override
  String toString() => 'FileEntry($name, $kind)';
}

/// A file operation that did not happen, with what the user should be told.
/// The cause is kept for the log, never for the sentence.
class FileSpaceException implements Exception {
  const FileSpaceException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() =>
      'FileSpaceException: $message${cause == null ? '' : ' ($cause)'}';
}

/// The filesystem of one machine. Implementations are cheap to build and hold
/// whatever connection they need open until [close].
abstract class FileSpace {
  /// The environment every path here belongs to — `windows`, `wsl:<distro>`,
  /// `ssh:<hostId>`. A path from another environment is refused, never guessed
  /// at.
  String get environmentId;

  /// What this side is called on screen: "This machine", "pi@box".
  String get label;

  /// How paths are spelled here — separators, roots, case. Windows paths and
  /// POSIX paths are not interchangeable, so the browser asks rather than
  /// assuming the one it is running on.
  p.Context get pathContext;

  /// Where a browser opens: the user's home directory.
  Future<EnvironmentPath> home();

  /// [path] made absolute here.
  Future<EnvironmentPath> resolve(EnvironmentPath path);

  /// The entries of [directory] — directories first, then name, ignoring case.
  Future<List<FileEntry>> list(EnvironmentPath directory);

  /// Creates a directory named [name] inside [parent] and answers its path.
  Future<EnvironmentPath> createDirectory(EnvironmentPath parent, String name);

  /// Creates an empty file named [name] inside [parent] and answers its path.
  Future<EnvironmentPath> createFile(EnvironmentPath parent, String name);

  /// Renames [target] to [name] **in the directory it is already in** — a
  /// rename is never a move somewhere else by accident.
  Future<EnvironmentPath> rename(EnvironmentPath target, String name);

  /// Deletes [target]. A directory with anything in it needs [recursive],
  /// so a stray click cannot take a tree with it.
  Future<void> delete(EnvironmentPath target, {bool recursive = false});

  /// Copies the file at [source] — on this machine — to [destination] on the
  /// local disk. [onProgress] is called with the bytes moved so far.
  Future<void> copyToLocal(
    EnvironmentPath source,
    String destination, {
    void Function(int bytes)? onProgress,
  });

  /// Copies the local file at [source] to [destination] here.
  Future<void> copyFromLocal(
    String source,
    EnvironmentPath destination, {
    void Function(int bytes)? onProgress,
  });

  /// The same place spelled for `dart:io` on this desktop, or null when this
  /// machine's files can only be reached by asking it. What tells a copy
  /// whether it is bytes over a wire or a file the process can open itself.
  String? hostPathOf(EnvironmentPath path);

  /// Releases whatever this held open. The SSH connection itself is not this
  /// object's to close.
  Future<void> close();

  /// The directory [path] is in, or null at the root.
  EnvironmentPath? parentOf(EnvironmentPath path) {
    final parent = pathContext.dirname(path.path);
    if (parent == path.path || parent.isEmpty) return null;
    return EnvironmentPath(environmentId: environmentId, path: parent);
  }

  /// [name] inside [directory].
  EnvironmentPath child(EnvironmentPath directory, String name) =>
      EnvironmentPath(
        environmentId: environmentId,
        path: pathContext.join(directory.path, name),
      );

  /// Refuses a path from another machine before anything is written with it.
  void requireOwnPath(EnvironmentPath path) {
    if (path.environmentId == environmentId) return;
    throw FileSpaceException(
      '${path.path} is on "${path.environmentId}", not $label',
    );
  }
}

/// A name that cannot be a file: empty, a path of its own, or one of the two
/// directory entries every listing hides. Checked before the filesystem sees
/// it, because "create a folder called `../x`" is a surprise, not an error.
String? nameRefusal(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return 'A name is needed.';
  if (trimmed == '.' || trimmed == '..') return 'That name is taken.';
  if (trimmed.contains('/') || trimmed.contains(r'\')) {
    return 'A name cannot contain a path separator.';
  }
  return null;
}
