/// A folder's path as a row can afford to show it, **longest first**: the whole
/// path with the home folder as `~`, then every parent cut to a letter the way
/// fish does (`~/D/p/popupbits-ai-workspace`), then the last folder alone.
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

  String join(Iterable<String> parts) {
    final body = parts.join(separator);
    return root.isEmpty ? '$lead$body' : '$root$separator$body';
  }

  final tail = segments.last;
  final parents = segments.sublist(0, segments.length - 1);
  final candidates = <String>[
    join(segments),
    if (parents.isNotEmpty) join([...parents.map(_initial), tail]),
    if (parents.isNotEmpty || root.isNotEmpty || lead.isNotEmpty)
      '…$separator$tail',
  ];
  // A short path abbreviates to itself; say it once.
  final seen = <String>{};
  return [
    for (final candidate in candidates)
      if (seen.add(candidate)) candidate,
  ];
}

/// `/Users/me`, `/home/me`, `C:\Users\me` — the folder a shell writes as `~`.
final _home = RegExp(
  r'^(?:/Users/[^/]+|/home/[^/]+|[A-Za-z]:\\Users\\[^\\]+)(?=$|[/\\])',
);

final _drive = RegExp(r'^[A-Za-z]:');

/// A parent folder, cut the way fish cuts it: one letter, and the dot of a
/// hidden folder kept so `.config` does not read as `c`.
String _initial(String segment) {
  if (segment.startsWith('.') && segment.length > 1) {
    return segment.substring(0, 2);
  }
  return segment.substring(0, 1);
}
