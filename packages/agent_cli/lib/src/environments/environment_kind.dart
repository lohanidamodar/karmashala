import 'package:path/path.dart' as p;

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


/// Whether a CLI store in [kind] can be read and written from this machine.
///
/// What `CliStoreLocator.locate` actually walks: the local host, and the WSL
/// distributions reachable over `\\wsl.localhost`. An [EnvironmentKind.ssh]
/// store is on somebody else's disk, so a lookup there comes back empty —
/// which reads exactly like a transcript that was deleted, and callers that
/// cannot tell the two apart refuse work they could have done.
bool cliStoreIsReachable(EnvironmentKind kind) =>
    isLocalHost(kind) || kind == EnvironmentKind.wsl;

/// The path context for a **store home this host can reach** in [kind].
///
/// Deliberately not [usesWindowsPaths], which answers a different question.
/// Paths *inside* WSL are POSIX, so `usesWindowsPaths(wsl)` is false — but the
/// store home `CliStoreLocator` hands back for a WSL distribution is the
/// `\\wsl.localhost\…` UNC form, which is a Windows path. Joining onto it with
/// the POSIX context would be a quiet behaviour change for every WSL user.
///
/// So: POSIX for a local Mac or Linux host and for SSH, whose stores really are
/// POSIX paths; Windows for a Windows host, for WSL's UNC form, and for an
/// unknown kind, which keeps the default the callers had.
///
/// It lives here because getting it wrong is silent and looks like being
/// logged out: three callers each hard-coded `p.windows`, which on a Mac turned
/// `/Users/me/.codex` into `/Users/me\auth.json` — a file that cannot exist —
/// so a signed-in account reported itself signed out and usage could never be
/// read.
p.Context storePathContextFor(EnvironmentKind? kind) => switch (kind) {
  EnvironmentKind.localPosix || EnvironmentKind.ssh => p.posix,
  _ => p.windows,
};
