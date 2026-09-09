/// Splitting a unified diff into files and hunks, and putting a chosen subset
/// back together as a patch `git apply` accepts.
///
/// Pure text work, deliberately: Git produces the diff and Git applies the
/// result, so the only thing this file owns is the arithmetic in between — and
/// that arithmetic is the part that is easy to get quietly wrong. Dropping a
/// hunk changes where every later hunk lands in the *new* file, so a patch made
/// by deleting `@@` blocks from git's output is wrong in a way `git apply` will
/// often accept anyway (it searches for context) and `git apply --cached` will
/// not.
library;

/// One `@@` block of a unified diff.
class DiffHunk {
  const DiffHunk({
    required this.oldStart,
    required this.oldCount,
    required this.newStart,
    required this.newCount,
    required this.heading,
    required this.lines,
  });

  /// First line of the range this hunk replaces, in the pre-image (1-based).
  final int oldStart;
  final int oldCount;

  /// First line of the range this hunk produces, in the post-image (1-based),
  /// **as git wrote it** — valid only when every earlier hunk is applied too.
  final int newStart;
  final int newCount;

  /// Whatever git put after the closing `@@` — usually the enclosing function.
  final String heading;

  /// Body lines, each keeping its leading ` `, `+`, `-` or `\`.
  final List<String> lines;

  /// How many lines this hunk adds to the file. Kept hunks shift the ones after
  /// them by exactly this much.
  int get delta => newCount - oldCount;

  int get addedLines => lines.where((l) => l.startsWith('+')).length;
  int get removedLines => lines.where((l) => l.startsWith('-')).length;

  /// A one-line summary for a picker: `@@ -a,b +c,d @@`.
  String get header => headerAt(newStart);

  String headerAt(int start) {
    final old = oldCount == 1 ? '$oldStart' : '$oldStart,$oldCount';
    final now = newCount == 1 ? '$start' : '$start,$newCount';
    return '@@ -$old +$now @@$heading';
  }
}

/// One file's section of a unified diff: its headers and its hunks.
class FilePatch {
  const FilePatch({
    required this.path,
    required this.oldPath,
    required this.headerLines,
    required this.hunks,
    required this.isBinary,
  });

  /// The post-image path (`b/…`). For a deletion this is still the file that
  /// was removed, so a caller always has one name to show.
  final String path;

  /// The pre-image path (`a/…`), different from [path] only for a rename.
  final String oldPath;

  /// Everything before the first `@@` — `diff --git`, `index`, mode lines,
  /// `---`/`+++`, and for a binary file the `GIT binary patch` payload.
  final List<String> headerLines;

  final List<DiffHunk> hunks;

  /// Binary files have no hunks to choose between; they are all or nothing.
  final bool isBinary;

  bool get isRename => oldPath != path;
  bool get isNew => headerLines.any((l) => l.startsWith('new file mode'));
  bool get isDeleted =>
      headerLines.any((l) => l.startsWith('deleted file mode'));

  /// This file's whole section, byte-for-byte as git wrote it.
  String get text {
    final buffer = StringBuffer();
    for (final line in headerLines) {
      buffer.writeln(line);
    }
    for (final hunk in hunks) {
      buffer.writeln(hunk.header);
      for (final line in hunk.lines) {
        buffer.writeln(line);
      }
    }
    return buffer.toString();
  }
}

/// Splits [diff] — the output of any `git diff` — into one [FilePatch] per file.
///
/// Tolerant by design: text it does not recognise before the first `diff --git`
/// is ignored, and a file whose body it cannot read as hunks comes back with an
/// empty [FilePatch.hunks] rather than throwing. A diff this cannot split must
/// never stop the diff being *shown*.
List<FilePatch> splitUnifiedDiff(String diff) {
  final files = <FilePatch>[];
  final lines = diff.split('\n');

  var index = 0;
  while (index < lines.length && !lines[index].startsWith('diff --git ')) {
    index++;
  }

  while (index < lines.length) {
    final header = <String>[lines[index]];
    final paths = _pathsFrom(lines[index]);
    index++;

    // Headers run until the first hunk or the next file.
    var binary = false;
    while (index < lines.length &&
        !lines[index].startsWith('@@ ') &&
        !lines[index].startsWith('diff --git ')) {
      if (lines[index].startsWith('Binary files ') ||
          lines[index].startsWith('GIT binary patch')) {
        binary = true;
      }
      header.add(lines[index]);
      index++;
    }

    final hunks = <DiffHunk>[];
    while (index < lines.length && lines[index].startsWith('@@ ')) {
      final range = _parseHunkHeader(lines[index]);
      index++;
      final body = <String>[];
      while (index < lines.length &&
          !lines[index].startsWith('@@ ') &&
          !lines[index].startsWith('diff --git ')) {
        // git's final newline leaves one empty element from the split; a body
        // line always carries a marker, so an empty string cannot be one.
        if (lines[index].isEmpty && index == lines.length - 1) break;
        body.add(lines[index]);
        index++;
      }
      if (range != null) {
        hunks.add(
          DiffHunk(
            oldStart: range.oldStart,
            oldCount: range.oldCount,
            newStart: range.newStart,
            newCount: range.newCount,
            heading: range.heading,
            lines: body,
          ),
        );
      }
    }

    // Drop a trailing blank left by the split at the very end of the diff.
    while (header.isNotEmpty && header.last.isEmpty) {
      header.removeLast();
    }

    files.add(
      FilePatch(
        path: paths.$2,
        oldPath: paths.$1,
        headerLines: header,
        hunks: hunks,
        isBinary: binary,
      ),
    );

    while (index < lines.length && !lines[index].startsWith('diff --git ')) {
      index++;
    }
  }

  return files;
}

/// Which hunks of which file a caller wants. An empty [hunks] means the whole
/// file, which is the only thing a binary file or a pure rename can offer.
class HunkSelection {
  const HunkSelection(this.path, {this.hunks = const []});

  final String path;
  final List<int> hunks;

  bool get isWholeFile => hunks.isEmpty;
}

/// Rebuilds a patch out of [files], keeping only what [selection] asks for.
///
/// The post-image line numbers are recomputed: a kept hunk starts where the
/// hunks kept *before it* have left the file, not where git said it would start
/// with every hunk applied. Dropping a hunk that adds two lines moves everything
/// after it back by two, and a patch that does not say so is a patch that
/// applies to a file that does not exist.
///
/// Returns an empty string when nothing was selected — callers must treat that
/// as "nothing to do" rather than handing it to `git apply`, which rejects an
/// empty patch.
String buildPatch(List<FilePatch> files, List<HunkSelection> selection) {
  final wanted = {for (final s in selection) s.path: s};
  final buffer = StringBuffer();

  for (final file in files) {
    final choice = wanted[file.path];
    if (choice == null) continue;

    if (file.isBinary || file.hunks.isEmpty || choice.isWholeFile) {
      buffer.write(file.text);
      continue;
    }

    final keep = choice.hunks.toSet();
    var offset = 0;
    final body = StringBuffer();
    for (var i = 0; i < file.hunks.length; i++) {
      final hunk = file.hunks[i];
      if (!keep.contains(i)) continue;
      body.writeln(hunk.headerAt(hunk.oldStart + offset));
      for (final line in hunk.lines) {
        body.writeln(line);
      }
      offset += hunk.delta;
    }
    if (body.isEmpty) continue;

    for (final line in file.headerLines) {
      buffer.writeln(line);
    }
    buffer.write(body);
  }

  return buffer.toString();
}

/// Convenience: the patch for [hunks] of [path] within [diff].
String patchForHunks(String diff, String path, List<int> hunks) =>
    buildPatch(splitUnifiedDiff(diff), [HunkSelection(path, hunks: hunks)]);

/// Convenience: the patch for whole files within [diff].
String patchForFiles(String diff, List<String> paths) => buildPatch(
  splitUnifiedDiff(diff),
  [for (final path in paths) HunkSelection(path)],
);

// --- internals ---------------------------------------------------------------

final _hunkHeader = RegExp(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)$');

({int oldStart, int oldCount, int newStart, int newCount, String heading})?
_parseHunkHeader(String line) {
  final m = _hunkHeader.firstMatch(line);
  if (m == null) return null;
  return (
    oldStart: int.parse(m.group(1)!),
    // A missing count means exactly one line, which is how git writes it.
    oldCount: int.tryParse(m.group(2) ?? '1') ?? 1,
    newStart: int.parse(m.group(3)!),
    newCount: int.tryParse(m.group(4) ?? '1') ?? 1,
    heading: m.group(5) ?? '',
  );
}

/// Pulls `a/<old>` and `b/<new>` out of a `diff --git` line.
///
/// Paths with spaces make this ambiguous in general; git's own answer is the
/// `---`/`+++` lines, but those are absent for a pure mode change. Splitting on
/// ` b/` from the right handles every name that does not itself contain that
/// sequence, and a name that does falls back to the whole remainder rather than
/// to nothing.
(String, String) _pathsFrom(String header) {
  final rest = header.substring('diff --git '.length);
  final split = rest.lastIndexOf(' b/');
  if (split < 0 || !rest.startsWith('a/')) return (rest, rest);
  return (rest.substring(2, split), rest.substring(split + 3));
}
