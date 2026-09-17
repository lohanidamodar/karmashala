/// A folder's path as a row can afford to show it, **longest first**: the whole
/// path with the home folder as `~`, then the last folder alone behind an
/// ellipsis (`…/popupbits-ai-workspace`). Nothing in between: a parent cut to a
/// letter (`~/D/p/…`) was read as noise, not as a place.
///
/// The last folder is never cut here: it is the part that tells two clones
/// apart from their parents, and the only part an end-ellipsis would lose.
/// Pure, and meant to be computed once per row of a tree — not per build.
List<String> abbreviatePath(String path) {
  final trimmed = path.trim();
  if (trimmed.isEmpty) return const [];
  final windows = trimmed.contains(r'\') && !trimmed.contains('/');
  final separator = windows ? r'\' : '/';

  var rest = trimmed;
  var root = '';
  final home = _home.firstMatch(rest);
  if (home != null) {
    root = '~';
    rest = rest.substring(home.end);
  } else if (windows && _drive.hasMatch(rest)) {
    root = rest.substring(0, 2);
    rest = rest.substring(2);
  }
  final segments = rest.split(separator).where((s) => s.isNotEmpty).toList();
  // A POSIX root that is not a home keeps its leading slash.
  final lead = root.isEmpty && !windows && trimmed.startsWith('/') ? '/' : '';
  if (segments.isEmpty) return [root.isEmpty ? trimmed : root];

  final body = segments.join(separator);
  final whole = root.isEmpty ? '$lead$body' : '$root$separator$body';
  final tail = '…$separator${segments.last}';
  final cut = segments.length > 1 || root.isNotEmpty || lead.isNotEmpty;
  return [whole, if (cut) tail];
}

/// `/Users/me`, `/home/me`, `C:\Users\me` — the folder a shell writes as `~`.
final _home = RegExp(
  r'^(?:/Users/[^/]+|/home/[^/]+|[A-Za-z]:\\Users\\[^\\]+)(?=$|[/\\])',
);

final _drive = RegExp(r'^[A-Za-z]:');
