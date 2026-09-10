/// Finding the file paths in a transcript, **by shape alone**.
///
/// Nothing here touches the disk: the transcript is re-parsed on a two-second
/// poll and a long one holds hundreds of path-shaped tokens. The one stat
/// happens in the click handler, where "that file is not there" is the right
/// thing to find out.
///
/// A token is a path when it contains a separator and is anchored by a drive or
/// UNC prefix, a leading `/` with two segments, a `./`, an extension, or a
/// trailing separator with two of them. One separator is not enough (`and/or`,
/// `1/2`), a match may not start mid-token (which keeps a URL whole), and `~/…`
/// is unmatched because expanding `~` needs a HOME we do not have.
library;

import 'package:path/path.dart' as p;

import 'package:agent_cli/process.dart';

/// One segment's characters, and the same set with `.` allowed inside it.
/// `~` is excluded on purpose — see the `~/` note above.
const _wordChar = r'[\w+%@-]';
const _dotChar = r'[\w.+%@-]';

/// One path segment: never ends in a dot, so a sentence's full stop is left
/// outside the link.
const _segment = '[.]?$_wordChar+(?:[.]$_wordChar+)*';

/// A segment whose last dot-part reads as a file extension. Letters first and
/// at most eight of them, so a version (`1.4.0`) is not an extension.
const _segmentWithExtension = '$_segment[.][A-Za-z][A-Za-z0-9]{0,7}';

const _sep = r'[\\/]';

/// What may follow a drive, UNC or dot anchor: path characters, never ending
/// on a dot.
const _tail = '(?:$_dotChar|$_sep)*(?:$_wordChar|$_sep)';

/// The characters that, immediately before a candidate, mean we are in the
/// middle of something else — a URL, a longer path, a word, a `~`.
const _notAfter = r'(?<![\w.+%@:~/\\-])';

/// ...and the mirror of it. Without this a partial match is worse than none:
/// `he/she/they` would linkify as `he/she/`, because every path-shaped prefix
/// of a phrase is itself path-shaped. `.` is deliberately absent: a path is
/// very often the last thing in a sentence.
const _notBefore = r'(?![\w+%@/\\-])';

/// A trailing `:12` or `:12:5`, as every compiler and `grep -n` prints it.
const _lineSuffix = r'(?::\d+(?::\d+)?)?';

/// The one compiled detector. A top-level `final` because it is compiled once
/// for the life of the process; a `RegExp` per row is the cost this file avoids.
final RegExp kTranscriptPathPattern = RegExp(
  '$_notAfter'
  '(?:'
  // C:\src\app, C:/src/app
  '[A-Za-z]:$_sep$_tail'
  // \\wsl.localhost\Ubuntu\home\me
  r'|\\\\[\w.$-]+'
  '$_sep$_tail'
  // ./relative, ../relative
  '|[.]{1,2}$_sep$_tail'
  // /home/me/src — two segments minimum, so a stray "/word" stays prose.
  '|(?:/$_segment){2,}/?'
  // lib/main.dart, windows/installer/output/Karmashala-Setup-1.4.0.exe
  '|$_segment(?:$_sep$_segment)*$_sep$_segmentWithExtension'
  // lib/src/features/ — no extension, so it must end in a separator and
  // carry two of them.
  '|$_segment(?:$_sep$_segment)+$_sep'
  ')'
  '$_lineSuffix'
  '$_notBefore',
);

/// A path found in a transcript.
class TranscriptPathToken {
  const TranscriptPathToken({required this.text, required this.path, this.line});

  /// Exactly the characters matched, as the agent wrote them — including any
  /// `:12`. This is what the link shows.
  final String text;

  /// [text] without the line suffix: the part that names a file.
  final String path;

  /// The line the token pointed at, when it carried one. Recorded because it is
  /// free to keep; nothing opens an editor at it yet.
  final int? line;

  @override
  String toString() => 'TranscriptPathToken($text)';
}

/// The token [match] found, split from its `:12` suffix.
TranscriptPathToken tokenForMatch(String matched) {
  final colon = matched.indexOf(':', 2);
  if (colon < 0) return TranscriptPathToken(text: matched, path: matched);
  final suffix = matched.substring(colon + 1);
  final line = int.tryParse(suffix.split(':').first);
  return TranscriptPathToken(
    text: matched,
    path: matched.substring(0, colon),
    line: line,
  );
}

/// The path token starting exactly at [start] in [source], or null. Anchored
/// rather than searching, because the markdown inline parser asks position by
/// position and a search would report a match it cannot consume.
TranscriptPathToken? transcriptPathAt(String source, int start) {
  final match = kTranscriptPathPattern.matchAsPrefix(source, start);
  if (match == null) return null;
  return tokenForMatch(match[0]!);
}

/// Whether [index] sits inside a markdown link or image **label**, so
/// `[lib/main.dart](https://…)` stays the link it already is. The parser cannot
/// tell us — the label's nodes are built before the `]` that wraps them — so
/// this scans back for an unclosed `[`, only after the pattern has matched.
bool insideMarkdownLabel(String source, int index) {
  var closed = 0;
  for (var i = index - 1; i >= 0; i--) {
    final c = source.codeUnitAt(i);
    if (c == 0x0A) return false; // newline
    if (i > 0 && source.codeUnitAt(i - 1) == 0x5C) continue; // escaped
    if (c == 0x5D) {
      closed++;
    } else if (c == 0x5B) {
      if (closed == 0) return true;
      closed--;
    }
  }
  return false;
}

/// How paths in [kind] are spelled, for joining and normalising. Not
/// `storePathContextFor`, which answers where the *store home this host can
/// reach* is and hands back Windows for WSL; a path an agent writes inside WSL
/// is POSIX.
p.Context transcriptPathContext(EnvironmentKind? kind) =>
    kind != null && usesWindowsPaths(kind) ? p.windows : p.posix;

/// A path spelled the Windows way, whatever environment claims it.
final _windowsAbsolute = RegExp(r'^([A-Za-z]:[\\/]|\\\\)');

/// [token] resolved against [workingDirectory] — the session's, never the
/// process's. A relative path in a transcript is relative to where the agent
/// was standing, and this process's cwd is not that.
String resolveTranscriptPath(
  String token, {
  required String workingDirectory,
  required p.Context context,
}) {
  if (_windowsAbsolute.hasMatch(token)) return token;
  if (context.isAbsolute(token)) return context.normalize(token);
  return context.normalize(context.join(workingDirectory, token));
}
