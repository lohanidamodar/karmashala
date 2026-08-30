/// The kind of execution environment a command or path belongs to.
///
/// Used to keep Windows-native, WSL and remote paths from being treated as
/// interchangeable strings (architecture constraints 7 & 8).
enum EnvironmentKind {
  /// Native Windows (e.g. `C:\src\repo`).
  windowsNative,

  /// A WSL distribution (e.g. `/home/user/repo` inside `Ubuntu`).
  wsl,

  /// A remote POSIX host reached over SSH (e.g. `/home/user/repo` on
  /// `build-box:22`). Paths here belong to the *remote* filesystem and are never
  /// interchangeable with a local path that happens to spell the same.
  ssh,
}

/// Whether commands in [kind] are run by a POSIX shell.
///
/// WSL and SSH share a shell vocabulary (`bash -lc`, `/` separators, `command
/// -v`); Windows does not. Callers branch on this rather than repeating the
/// `wsl || ssh` pair, so a fourth POSIX-shaped environment stays a one-line
/// change.
bool isPosixShell(EnvironmentKind kind) =>
    kind == EnvironmentKind.wsl || kind == EnvironmentKind.ssh;
