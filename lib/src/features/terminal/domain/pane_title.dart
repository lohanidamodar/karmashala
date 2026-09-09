/// What a terminal tab is called.
///
/// Pure Dart on purpose — no xterm, no Flutter, no `Platform` — so the rules
/// are unit-testable and the caller supplies the observations.
library;

/// A working directory, shortened for a tab chip.
///
/// `~` for the home directory itself, `~/x` for one level below it, and the
/// last two segments otherwise: a tab is 220 pixels wide, so a full path is
/// ellipsised into uselessness and the end of it is the part that identifies
/// the shell. Both separators are accepted, because a Windows-first app runs
/// WSL panes whose paths are POSIX.
String directoryLabel(String path, {String? home}) {
  var normalized = _trimSlashes(path.replaceAll(r'\', '/'));
  if (normalized.isEmpty) return '/';

  final normalizedHome = home == null
      ? null
      : _trimSlashes(home.replaceAll(r'\', '/'));
  if (normalizedHome != null && normalizedHome.isNotEmpty) {
    if (_sameDirectory(normalized, normalizedHome)) return '~';
    if (_isBelow(normalized, normalizedHome)) {
      normalized = '~/${normalized.substring(normalizedHome.length + 1)}';
    }
  }

  final segments = normalized.split('/').where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty) return '/';
  if (segments.length == 1) return segments.single;
  return '${segments[segments.length - 2]}/${segments.last}';
}

String _trimSlashes(String path) {
  var end = path.length;
  while (end > 1 && path[end - 1] == '/') {
    end--;
  }
  return path.substring(0, end);
}

/// Windows paths are case-insensitive and POSIX ones are not; comparing
/// case-insensitively everywhere is wrong only in the vanishingly rare case of
/// two Linux directories differing by case, where the cost is a `~` that should
/// have been a path.
bool _sameDirectory(String a, String b) => a.toLowerCase() == b.toLowerCase();

bool _isBelow(String path, String parent) =>
    path.length > parent.length + 1 &&
    _sameDirectory(path.substring(0, parent.length), parent) &&
    path[parent.length] == '/';

/// Whether [title] is a pane reciting the program we launched rather than
/// saying anything about the work going on in it.
///
/// ConPTY hands the child's image path through as a pane's window title, so a
/// WSL pane opens announcing itself as `C:\Windows\System32\wsl.exe` — the
/// wrapper this app put in front of the shell, and the one thing about the pane
/// the user already knows.
///
/// Two conditions, and it takes both to stay narrow. The title has to be an
/// absolute path *and nothing else*, which leaves `user@host: /home/me/src` and
/// a bare `wsl` alone — those are real titles a real shell sends. And the file
/// it names has to be one of [launchers] itself, so a pane naming some other
/// path is still believed. Compared case-insensitively, because the path comes
/// from Windows and its casing is not ours to predict.
bool namesLauncher(String title, Set<String> launchers) {
  if (launchers.isEmpty || !_isAbsolutePath(title)) return false;
  return launchers.contains(_basename(title).toLowerCase());
}

/// Every image name a launch line names — [executable] itself and every `.exe`
/// token inside [arguments] — lowercased and without its directory.
///
/// **Every name, not just the first.** A WSL pane is spawned as
/// `cmd.exe /c wsl.exe -d <distro> …`, so the image that announces itself is
/// no longer the executable — and a filter that knew only the first name let
/// `C:\Windows\System32\wsl.exe` through as a tab label. The arguments are
/// searched rather than compared, because `throughCommandPrompt` joins the
/// whole line into one `/c` argument: the `.exe` is a token inside it, not
/// the end of it.
Set<String> launcherNames(String executable, List<String> arguments) => {
  _basename(executable).toLowerCase(),
  for (final argument in arguments)
    for (final match in _executableToken.allMatches(argument))
      _basename(match.group(0)!).toLowerCase(),
};

/// An image name inside a command line — `wsl.exe`, `C:\…\powershell.exe`.
/// Quotes and whitespace end a token, which is what keeps a quoted path with a
/// space in it from swallowing the flag after it.
final RegExp _executableToken = RegExp(r'[^\s"]+\.exe', caseSensitive: false);

/// Whether [path] is rooted — a drive (`C:\…`), a UNC share (`\\…`) or POSIX
/// (`/…`).
bool _isAbsolutePath(String path) {
  if (path.startsWith('/') || path.startsWith('\\')) return true;
  if (path.length < 3 || path[1] != ':') return false;
  if (path[2] != '\\' && path[2] != '/') return false;
  final drive = path.codeUnitAt(0) | 0x20;
  return drive >= 0x61 && drive <= 0x7a;
}

/// The last segment of [path], for either separator — a Windows-first app has
/// both, often in the same pane.
String _basename(String path) {
  final slash = path.lastIndexOf('/');
  final backslash = path.lastIndexOf('\\');
  final at = slash > backslash ? slash : backslash;
  return at < 0 ? path : path.substring(at + 1);
}
