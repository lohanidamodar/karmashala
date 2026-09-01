/// What one tool call in a transcript is actually *about*.
///
/// The transcript used to reduce every call to its tool name, which is why the
/// owner reported that "when commands are run … it feels like the command is
/// printed twice": two different `Bash` calls rendered the same string. A real
/// 265-message Claude Code transcript held 23 pairs of adjacent, byte-identical
/// tool rows standing for entirely different commands.
///
/// Everything here is read out of the agent's own record — Claude Code writes
/// `tool_use{name, input}` and answers it with a `tool_result` — so the fields
/// are what the wire actually carries and nothing is inferred.
class ToolActivity {
  const ToolActivity({
    required this.name,
    this.subject,
    this.imagePath,
    this.output,
    this.outputTruncated = false,
    this.isError = false,
  });

  /// The tool's own name: `Bash`, `Read`, `Edit`, `mcp__…`.
  final String name;

  /// The one line that identifies *this* call: the command it ran, the file it
  /// touched, the pattern it searched for. Null when the call carried nothing
  /// we recognise — better than inventing a summary of it.
  final String? subject;

  /// The image this call read, when it read one. Set only for a path that
  /// looks like an image ([looksLikeImagePath]); a `.dart` file is a [subject]
  /// and nothing more.
  final String? imagePath;

  /// What the tool answered, once the result arrived. Null while the call is
  /// still outstanding — which is also how a transcript ends mid-turn.
  final String? output;

  /// Whether [output] was cut short on the way in. Tool results are unbounded
  /// (a `Read` of a large file is megabytes) and the transcript is re-parsed on
  /// a two-second poll, so the reader keeps a bounded head of each one.
  final bool outputTruncated;

  /// Whether the agent was told the call failed (`tool_result.is_error`).
  final bool isError;

  /// The one-line form: what Copy puts on the clipboard, and what the remote
  /// and companion payloads carry. Deliberately the same shape the CLIs print.
  String get summary {
    final s = subject;
    return s == null || s.isEmpty ? name : '$name($s)';
  }

  ToolActivity withResult({
    String? output,
    bool outputTruncated = false,
    bool isError = false,
  }) => ToolActivity(
    name: name,
    subject: subject,
    imagePath: imagePath,
    output: output,
    outputTruncated: outputTruncated,
    isError: isError,
  );
}

/// The extensions Flutter's decoder can open, and the ones the composer already
/// offers to attach. A path outside this set is never handed to `Image.file`.
const Set<String> kPreviewableImageExtensions = {
  'png',
  'jpg',
  'jpeg',
  'gif',
  'webp',
  'bmp',
};

/// Whether [path] names a file we would try to draw.
///
/// Extension only: this runs while parsing a transcript, where the file may be
/// on another machine, already deleted, or behind a WSL share — none of which
/// can be sniffed without touching the disk.
bool looksLikeImagePath(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0 || dot == path.length - 1) return false;
  final ext = path.substring(dot + 1).toLowerCase();
  return kPreviewableImageExtensions.contains(ext);
}

/// The input keys that carry the identifying line of a call, most specific
/// first. Read off Claude Code's own tool schemas: `Bash` has `command`,
/// `Read`/`Write`/`Edit` have `file_path`, `Grep`/`Glob` have `pattern`, and a
/// subagent (`Task`) is best named by its `description`.
const List<String> kToolSubjectKeys = [
  'command',
  'file_path',
  'notebook_path',
  'path',
  'pattern',
  'url',
  'query',
  'description',
];

/// The identifying line for a tool call's `input` map, or null when it carries
/// none of the keys we know. Returns the key alongside it, because only some
/// keys name a *file* (see [toolActivityFor]).
MapEntry<String, String>? toolSubjectEntryFor(Object? input) {
  if (input is! Map) return null;
  for (final key in kToolSubjectKeys) {
    final value = input[key];
    if (value is String && value.trim().isNotEmpty) {
      return MapEntry(key, value.trim());
    }
  }
  return null;
}

/// The keys whose value is a path to one file, and therefore the only ones that
/// may become an [ToolActivity.imagePath].
///
/// A `command` is not one of them, however it ends: `convert a.png b.png` ends
/// in `.png` and names no single file to draw.
const Set<String> kToolFileKeys = {'file_path', 'notebook_path', 'path'};

/// Builds the activity for a `tool_use`-shaped call.
ToolActivity toolActivityFor(String name, Object? input) {
  final entry = toolSubjectEntryFor(input);
  final subject = entry?.value;
  final isFile = entry != null && kToolFileKeys.contains(entry.key);
  return ToolActivity(
    name: name,
    subject: subject,
    imagePath: isFile && looksLikeImagePath(subject!) ? subject : null,
  );
}
