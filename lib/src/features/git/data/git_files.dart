import 'dart:io';

import '../../../core/process/path_translator.dart';
import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/environment_path.dart';
import '../../environments/domain/execution_environment.dart';

/// The few filesystem operations this feature needs, behind an interface so a
/// test can watch them without a disk.
///
/// Everything else here goes through `git`, which is the point: this exists
/// only where a process would be paid for something a file already says. Two
/// things git needs cannot be handed to it as arguments — a private index needs
/// a git directory to live in, and `git apply` needs its patch as a file, and
/// `CommandRunner` has no stdin and no environment, deliberately. [readString]
/// is the other direction: two facts a delivery row wants are single lines in
/// `.git`, and a read of them costs no `CreateProcessW` at all.
abstract interface class GitFiles {
  Future<bool> exists(String path);
  Future<void> createDirectory(String path);

  /// Writes [contents] to [path], replacing whatever was there.
  Future<void> writeString(String path, String contents);

  /// The contents of [path], or **null when it could not be read** — absent,
  /// unreadable, or a directory rather than a file.
  ///
  /// One null for all three on purpose. Every caller here treats "could not
  /// read" as "ask git instead", so distinguishing the reasons would cost an
  /// extra `stat` per call to reach the same branch — and on a
  /// `\\wsl.localhost` share a `stat` is the expense being avoided. A caller
  /// that opens `<checkout>/.git` and gets null has learned the useful thing:
  /// it is not a worktree pointer file.
  Future<String?> readString(String path);
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

  @override
  Future<String?> readString(String path) async {
    try {
      return await File(path).readAsString();
    } on IOException {
      // Absent, a directory, locked, or on a share that has gone away. See
      // [GitFiles.readString] for why all of those are one answer.
      return null;
    } on FormatException {
      // Not UTF-8. `.git/config` and a ref file are ASCII in practice; a file
      // that is not is not one this reader can speak for.
      return null;
    }
  }
}

/// Maps a path as git sees it in its own environment onto a path this process
/// can open.
///
/// The identity is correct for a Windows repository driven by the Windows app —
/// the case Karmashala is built around — and wrong for anything the host
/// cannot reach directly, which is why it is a seam rather than an assumption.
typedef HostPathOf = String Function(String environmentPath);

String sameEnvironmentPath(String path) => path;

/// Maps a path as git sees it onto one this process can open, or answers
/// **null when it cannot be opened from here at all**.
///
/// The nullable counterpart of [HostPathOf], for callers that are pure
/// optimisation: a repository on an SSH host has no path this process can open,
/// so the answer is "ask git over the transport", not an error.
typedef HostPathOrNone = String? Function(String environmentPath);

/// How a path inside [env] is spelled for this process. See [HostPathOrNone]
/// for why an unreachable environment is a null answer rather than a throw —
/// `CheckpointService` keeps its own throwing version, because for a checkpoint
/// the absence is a refusal the user has to be told about in a sentence.
HostPathOrNone hostPathMapperFor(ExecutionEnvironment env) => switch (env.kind) {
  // Already this process's own filesystem, whichever local OS it is.
  EnvironmentKind.windowsNative ||
  EnvironmentKind.localPosix => (path) => path,
  // Reachable, as a `\\wsl.localhost\<distro>\…` UNC share. Not free — §18
  // measures a listing there at 0.79 ms warm — but far cheaper than a process.
  EnvironmentKind.wsl => (path) {
    try {
      return const PathTranslator()
          .translate(
            EnvironmentPath(environmentId: env.id, path: path),
            from: env,
            to: ExecutionEnvironment(
              id: 'windows',
              kind: EnvironmentKind.windowsNative,
              name: 'Windows',
              createdAt: DateTime.utc(2020),
            ),
          )
          .path;
    } on PathTranslationException {
      // A WSL row with no distribution name, or a path shape the translator
      // does not know. Unmappable is the same as unreachable here.
      return null;
    }
  },
  // Another machine's filesystem. Nothing local names it.
  EnvironmentKind.ssh => (_) => null,
};
