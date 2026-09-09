/// Finding the file paths in a transcript, **by shape alone**.
///
/// The rule this file exists to enforce: nothing here touches the disk. The
/// transcript is re-parsed on a two-second poll and a long one holds hundreds
/// of path-shaped tokens; a `\\wsl.localhost\…` stat costs ~1.2 ms against
/// 0.07 ms locally (the measurement in `TranscriptImagePreview`), so statting
/// candidates to decide what to underline would reintroduce exactly the lag
/// this app already fixed once. A token is linkified on its spelling, and the
/// one stat happens in the click handler — where "that file is not there" is
/// the right thing to find out.
///
/// ## The detection rule, and where the line is drawn
///
/// A token is a path when it **contains a directory separator** and is
/// **anchored** by at least one of:
///
/// * a drive or UNC prefix — `C:\src\app`, `\\wsl.localhost\Ubuntu\home\me`;
/// * a leading `/` with two or more segments — `/home/me/src`;
/// * a leading `./` or `../`;
/// * an extension on its last segment — `windows/installer/output/x.exe`;
/// * a trailing separator, with at least two of them — `lib/src/features/`.
///
/// Everything else stays prose, and each exclusion is a case that actually
/// occurs:
///
/// * **A separator is required**, so a bare word with a dot is never a link:
///   `e.g.`, `i.e.`, a version like `1.4.0`, `Node.js`, a sentence that ends in
///   a word. This costs us `main.dart` written on its own — a deliberate miss,
///   because the alternative underlines punctuation.
/// * **One separator is not enough** without an extension, so `and/or`, `n/a`
///   and `1/2` are prose. `he/she/they` survives the two-separator case too,
///   because a no-extension relative path also has to end in a separator.
/// * **A token may not start mid-token** (the lookbehind), which is what keeps
///   `https://example.com/a/b` whole: every interior position of a URL is
///   preceded by a path character, so none of them can start a match.
/// * `~/…` is deliberately **not** matched. Expanding `~` needs the agent's
///   HOME, which we do not have for another environment, and a link that can
///   never resolve is worse than plain text.
///
/// What this costs us is directories written without a trailing separator
/// (`test/features/sessions`). That is the honest price: nothing distinguishes
/// them from a slash-joined English phrase.
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
/// `he/she/they` would linkify as `he/she/`, and `2/9/2026` as `2/9/`, because
/// every path-shaped prefix of a phrase is itself path-shaped. `.` is
/// deliberately absent: a path is very often the last thing in a sentence.
const _notBefore = r'(?![\w+%@/\\-])';

/// A trailing `:12` or `:12:5`, as every compiler and `grep -n` prints it.
const _lineSuffix = r'(?::\d+(?::\d+)?)?';

/// The one compiled detector. A top-level `final` because it is compiled once
/// for the life of the process: a `RegExp` built per message, per row or per
/// build is the cost this whole file is written to avoid.
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

/// The path token starting exactly at [start] in [source], or null.
///
/// Anchored rather than searching, because the markdown inline parser asks
/// position by position and a search would report a match it cannot consume.
TranscriptPathToken? transcriptPathAt(String source, int start) {
  final match = kTranscriptPathPattern.matchAsPrefix(source, start);
  if (match == null) return null;
  return tokenForMatch(match[0]!);
}

/// Whether [index] sits inside a markdown link or image **label**.
///
/// `[lib/main.dart](https://…)` is already a link and must stay the one it is.
/// The parser cannot tell us — the label's nodes are built before the `]` that
/// wraps them — so this scans back for an unclosed `[` on the same line. It
/// runs only after the pattern has already matched, which is rare, so the scan
/// is not on the hot path.
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

/// How paths in [kind] are spelled, for joining and normalising.
///
/// Not `storePathContextFor`, which answers a different question: that one is
/// about the *store home this host can reach*, and hands back Windows for WSL
/// because a WSL store is reached through its UNC form. A path an agent writes
/// inside WSL is POSIX.
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
