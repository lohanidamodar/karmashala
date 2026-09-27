/// One browsable, readable, writable filesystem, so this machine's disk, a
/// WSL distribution and a host over SFTP are the same thing to a file pane,
/// an editor's buffers and Quick Open. Every path is an [EnvironmentPath]: a
/// name on its own has no machine.
library;

import 'dart:typed_data';

import 'package:agent_cli/process.dart';
import 'package:path/path.dart' as p;

import 'file_values.dart';

/// A file operation that did not happen, with what a person should be told.
/// The cause is kept for the log, never for the sentence.
class FileSpaceException implements Exception {
  const FileSpaceException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() =>
      'FileSpaceException: $message${cause == null ? '' : ' ($cause)'}';
}

/// The link to the environment is down: nothing was learned about the file.
/// Distinct from a refusal, because a buffer must neither be marked changed
/// nor lose its text over a dropped connection.
class FileUnreachableException extends FileSpaceException {
  const FileUnreachableException(super.message, {super.cause});
}

/// A write refused because the file is not the version it expected.
class FileStaleException extends FileSpaceException {
  FileStaleException(this.current)
    : super(
        current == null
            ? 'The file is no longer on disk.'
            : 'The file changed on disk.',
      );

  /// What is there now; null when the file is gone.
  final FileStamp? current;
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

  /// How paths are spelled here — separators, roots, case.
  p.Context get pathContext;

  /// Where a browser opens: the user's home directory.
  Future<EnvironmentPath> home();

  /// [path] made absolute here.
  Future<EnvironmentPath> resolve(EnvironmentPath path);

  /// The entries of [directory] — directories first, then name, ignoring case.
  /// Without [details] no entry carries a size or a time, which on this
  /// machine saves a stat per entry: what a walk of a checkout wants.
  Future<List<FileEntry>> list(EnvironmentPath directory, {bool details = true});

  /// What is at [path], following links. Throws [FileUnreachableException]
  /// when the environment did not answer.
  Future<FileStat> stat(EnvironmentPath path);

  /// [length] bytes of [path] from [offset], or to its end when null.
  Future<Uint8List> read(EnvironmentPath path, {int offset = 0, int? length});

  /// Replaces [path] with [bytes] if [expect] accepts what is there, creating
  /// it when [expect] allows absence. Answers the stamp now on disk. Throws
  /// [FileStaleException] when refused, [FileUnreachableException] when the
  /// environment dropped, and [FileSpaceException] otherwise.
  Future<FileStamp> write(
    EnvironmentPath path,
    Uint8List bytes, {
    required WriteExpectation expect,
  });

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

  /// Copies the file at [source] here to [destination] on the server's own
  /// disk. [onProgress] is called with the bytes moved so far.
  Future<void> copyToLocal(
    EnvironmentPath source,
    String destination, {
    void Function(int bytes)? onProgress,
  });

  /// Copies the server's own file at [source] to [destination] here.
  Future<void> copyFromLocal(
    String source,
    EnvironmentPath destination, {
    void Function(int bytes)? onProgress,
  });

  /// The same place spelled for `dart:io` on the server's machine, or null
  /// when this machine's files can only be reached by asking it.
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

  /// [name] inside [parent], after [nameRefusal] has had its say.
  EnvironmentPath target(EnvironmentPath parent, String name) {
    requireOwnPath(parent);
    final refusal = nameRefusal(name);
    if (refusal != null) throw FileSpaceException(refusal);
    return child(parent, name.trim());
  }

  /// Where [target] goes when renamed to [name]: beside itself.
  EnvironmentPath renamed(EnvironmentPath target, String name) {
    requireOwnPath(target);
    final refusal = nameRefusal(name);
    if (refusal != null) throw FileSpaceException(refusal);
    final parent = parentOf(target);
    if (parent == null) {
      throw const FileSpaceException('A root cannot be renamed.');
    }
    return child(parent, name.trim());
  }
}

/// Directories first, then by name ignoring case — how every listing sorts.
int compareFileEntries(FileEntry a, FileEntry b) {
  if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
  return a.name.toLowerCase().compareTo(b.name.toLowerCase());
}
