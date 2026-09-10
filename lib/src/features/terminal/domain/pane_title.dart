/// What a terminal tab is called. Pure Dart on purpose, so the rules are
/// unit-testable and the caller supplies the observations.
library;

/// A working directory shortened for a tab chip: `~`, `~/x`, or the last two
/// segments — a 220-pixel tab ellipsises a full path into uselessness.
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

/// Windows paths are case-insensitive and POSIX ones are not; folding case
/// everywhere is wrong only for two Linux directories differing by case, where
/// the cost is a `~` that should have been a path.
bool _sameDirectory(String a, String b) => a.toLowerCase() == b.toLowerCase();

bool _isBelow(String path, String parent) =>
    path.length > parent.length + 1 &&
    _sameDirectory(path.substring(0, parent.length), parent) &&
    path[parent.length] == '/';

/// Whether [title] is a pane reciting the program we launched: ConPTY passes
/// the child's image path through, so a WSL pane announces itself as `wsl.exe`.
bool namesLauncher(String title, Set<String> launchers) {
  if (launchers.isEmpty || !_isAbsolutePath(title)) return false;
  return launchers.contains(_basename(title).toLowerCase());
}

/// Every image name a launch line names, lowercased and without its directory.
/// **Every name, not just the first** — a WSL pane is spawned through
/// `cmd.exe`.
Set<String> launcherNames(String executable, List<String> arguments) => {
  _basename(executable).toLowerCase(),
  for (final argument in arguments)
    for (final match in _executableToken.allMatches(argument))
      _basename(match.group(0)!).toLowerCase(),
};

/// An image name inside a command line. Quotes and whitespace end a token,
/// which keeps a quoted path with a space in it from swallowing the next
/// flag.
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
