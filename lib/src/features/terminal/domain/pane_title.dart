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
