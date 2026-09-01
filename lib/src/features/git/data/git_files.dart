import 'dart:io';

/// The few filesystem operations the checkpoint machinery needs, behind an
/// interface so a test can watch them without a disk.
///
/// Everything else in this feature goes through `git`, which is the point: this
/// exists only because two things git needs cannot be handed to it as
/// arguments. A private index needs a git directory to live in, and `git apply`
/// needs its patch as a file — `CommandRunner` has no stdin and no environment,
/// deliberately, and widening it is a change to every runner in the app.
abstract interface class GitFiles {
  Future<bool> exists(String path);
  Future<void> createDirectory(String path);

  /// Writes [contents] to [path], replacing whatever was there.
  Future<void> writeString(String path, String contents);
}

/// [GitFiles] against the real filesystem, as this process sees it.
class HostGitFiles implements GitFiles {
  const HostGitFiles();

  @override
  Future<bool> exists(String path) => File(path).exists();

  @override
  Future<void> createDirectory(String path) =>
      Directory(path).create(recursive: true);

  @override
  Future<void> writeString(String path, String contents) =>
      File(path).writeAsString(contents);
}

/// Maps a path as git sees it in its own environment onto a path this process
/// can open.
///
/// The identity is correct for a Windows repository driven by the Windows app —
/// the case Karmashala is built around — and wrong for anything the host
/// cannot reach directly, which is why it is a seam rather than an assumption.
typedef HostPathOf = String Function(String environmentPath);

String sameEnvironmentPath(String path) => path;
