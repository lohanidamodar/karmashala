import 'dart:io';

import 'package:agent_cli/process.dart';

/// What is at a path, as far as this process can see.
///
/// [none] is *nothing is there* **and** *the lookup failed*: a dead
/// `\\wsl.localhost` share reports the same nothing an empty folder does, so a
/// [none] is never on its own an absence.
enum PathEntry { none, file, directory }

/// The few filesystem operations this feature needs, behind an interface so a
/// test can watch them without a disk.
///
/// Everything else goes through `git`. This exists only where a process would be
/// paid for something a file already says: a private index needs a git directory
/// to live in, `git apply` needs its patch as a file, and [readString] is two
/// single lines of `.git` for no `CreateProcessW` at all.
abstract interface class GitFiles {
  Future<bool> exists(String path);
  Future<void> createDirectory(String path);

  /// Writes [contents] to [path], replacing whatever was there.
  Future<void> writeString(String path, String contents);

  /// The contents of [path], or **null when it could not be read** — absent,
  /// unreadable, or a directory rather than a file.
  ///
  /// One null for all three on purpose: every caller treats "could not read" as
  /// "ask git instead", and on a `\\wsl.localhost` share the `stat` that would
  /// distinguish them is the expense being avoided.
  Future<String?> readString(String path);

  /// What is at [path] — see [PathEntry].
  ///
  /// The one `stat` this feature spends: a null from `<dir>/.git/config` cannot
  /// tell "there is no `.git`" from "`.git` is a directory I could not open".
  Future<PathEntry> typeOf(String path);
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

  @override
  Future<PathEntry> typeOf(String path) async {
    try {
      // Links are followed, so a `.git` symlinked to a real git directory reads
      // as a directory — which is what git makes of it too.
      return switch (await FileSystemEntity.type(path)) {
        FileSystemEntityType.file => PathEntry.file,
        FileSystemEntityType.directory => PathEntry.directory,
        _ => PathEntry.none,
      };
    } on FileSystemException {
      // A dead share, or a path this OS will not parse. See [PathEntry].
      return PathEntry.none;
    }
  }
}

/// Maps a path as git sees it in its own environment onto a path this process
/// can open.
///
/// The identity is right for a Windows repository driven by the Windows app and
/// wrong for anything the host cannot reach, so it is a seam not an assumption.
typedef HostPathOf = String Function(String environmentPath);

String sameEnvironmentPath(String path) => path;

/// Maps a path as git sees it onto one this process can open, or answers
/// **null when it cannot be opened from here at all**.
///
/// The nullable counterpart of [HostPathOf]: a repository on an SSH host has no
/// path this process can open, so the answer is "ask git over the transport".
typedef HostPathOrNone = String? Function(String environmentPath);

/// How a path inside [env] is spelled for this process, or null when it cannot be
/// opened from here. `CheckpointService` keeps its own throwing version, because
/// there the absence is a refusal the user has to be told about.
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
