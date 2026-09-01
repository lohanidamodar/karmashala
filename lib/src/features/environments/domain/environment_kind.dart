/// The kind of execution environment a command or path belongs to.
///
/// Used to keep Windows-native, WSL and remote paths from being treated as
/// interchangeable strings (architecture constraints 7 & 8).
enum EnvironmentKind {
  /// Native Windows (e.g. `C:\src\repo`).
  windowsNative,

  /// The local macOS or Linux host (e.g. `/Users/me/src/repo`).
  ///
  /// One member for both because nothing here distinguishes them: the shell,
  /// the path separator, the lookup command and the process model are the same.
  /// The few places that genuinely differ — which file manager to reveal in,
  /// where a desktop entry lives — branch on `Platform` at the point of use.
  /// [ExecutionEnvironment.name] carries "macOS" or "Linux" for display.
  ///
  /// Before this existed the desktop registered its host as [windowsNative] on
  /// every platform, so a Mac looked its agent CLIs up with `where` — a command
  /// it does not have — and found none of them.
  localPosix,

  /// A WSL distribution (e.g. `/home/user/repo` inside `Ubuntu`).
  wsl,

  /// A remote POSIX host reached over SSH (e.g. `/home/user/repo` on
  /// `build-box:22`). Paths here belong to the *remote* filesystem and are never
  /// interchangeable with a local path that happens to spell the same.
  ssh,
}

/// Whether commands in [kind] are run by a POSIX shell.
///
/// The local POSIX host, WSL and SSH share a shell vocabulary (`bash -lc`, `/`
/// separators, `command -v`); Windows does not. Callers branch on this rather
/// than listing the POSIX kinds, so a fifth POSIX-shaped environment stays a
/// one-line change.
bool isPosixShell(EnvironmentKind kind) =>
    kind == EnvironmentKind.localPosix ||
    kind == EnvironmentKind.wsl ||
    kind == EnvironmentKind.ssh;

/// Whether [kind] is *this machine* — the host the desktop app runs on.
///
/// The distinction that matters to most callers is "here" versus "somewhere
/// else with its own filesystem", not which OS is here. Anything that asked
/// `kind == windowsNative` to mean "local" asks this instead; the few that
/// really did mean Windows still say so.
bool isLocalHost(EnvironmentKind kind) =>
    kind == EnvironmentKind.windowsNative || kind == EnvironmentKind.localPosix;

/// Whether paths in [kind] are spelled the Windows way (`C:\...`, `\`).
///
/// Only [EnvironmentKind.windowsNative] is; every other kind is POSIX. Named,
/// so a call site reads as "how is this path spelled?" rather than as an
/// incidental equality test.
bool usesWindowsPaths(EnvironmentKind kind) =>
    kind == EnvironmentKind.windowsNative;
