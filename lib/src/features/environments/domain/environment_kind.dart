/// The kind of execution environment a command or path belongs to.
///
/// Used to keep Windows-native and WSL paths from being treated as
/// interchangeable strings (architecture constraints 7 & 8).
enum EnvironmentKind {
  /// Native Windows (e.g. `C:\src\repo`).
  windowsNative,

  /// A WSL distribution (e.g. `/home/user/repo` inside `Ubuntu`).
  wsl,
}
