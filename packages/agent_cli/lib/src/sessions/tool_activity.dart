import '../util/bounded_text.dart';
import '../agents/claude_code/claude_file_edits.dart';
import '../agents/domain/agent_plan.dart';
import '../agents/domain/file_edit.dart';
import 'tool_edits.dart';

export '../agents/domain/file_edit.dart';
export 'tool_edits.dart';

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
    this.plan,
    this.kind,
    this.edits = const [],
    this.editsTruncated = false,
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

  /// **The plan this call published**, for the one tool per CLI that publishes
  /// one. Null for every other call, which is nearly all of them.
  ///
  /// It rides here rather than in a second reader because the plan lives in a
  /// tool call's *input*, which the transcript parse already has decoded in its
  /// hand — so the panel that draws it adds no read, no parse and no poll (the
  /// property `sessionOutstandingCallsProvider` relies on for the same reason).
  /// The alternative was a second pass over the same file, and the owner's
  /// largest transcript is 43.8 MB.
  final AgentPlan? plan;

  /// What the agent says the call is, where its protocol says (ACP's `kind`:
  /// `edit`, `read`, `execute`, …). Null for a CLI transcript, which names
  /// the tool instead.
  final String? kind;

  /// The files this call writes and what it writes to them, already bounded
  /// by [boundedToolEdits]. Empty for every call that writes nothing.
  final List<FileEditRecord> edits;

  /// Whether [edits] lost content to the bound.
  final bool editsTruncated;

  /// The one-line form: what Copy puts on the clipboard, and what the remote
  /// and companion payloads carry. Deliberately the same shape the CLIs print.
  String get summary {
    final s = subject;
    return s == null || s.isEmpty || s == name ? name : '$name($s)';
  }

  /// The wire form a server's transcript page carries. Absent fields are
  /// null or false; [imagePath] is spelled as the server's machine spells it.
  Map<String, Object?> toJson() => {
    'name': name,
    'subject': ?subject,
    'imagePath': ?imagePath,
    'output': ?output,
    if (outputTruncated) 'outputTruncated': true,
    if (isError) 'isError': true,
    'plan': ?plan?.toJson(),
    'kind': ?kind,
    if (edits.isNotEmpty) 'edits': [for (final edit in edits) edit.toJson()],
    if (editsTruncated) 'editsTruncated': true,
  };

  /// Throws [FormatException] when `name` is not a string; any other field
  /// out of shape reads as absent.
  static ToolActivity fromJson(Map<String, Object?> json) {
    final name = json['name'];
    if (name is! String) throw const FormatException('tool: no name');
    final plan = json['plan'];
    final edits = json['edits'];
    return ToolActivity(
      name: name,
      subject: _stringOrNull(json['subject']),
      imagePath: _stringOrNull(json['imagePath']),
      output: _stringOrNull(json['output']),
      outputTruncated: json['outputTruncated'] == true,
      isError: json['isError'] == true,
      plan: plan is Map
          ? AgentPlan.fromJson(plan.cast<String, Object?>())
          : null,
      kind: _stringOrNull(json['kind']),
      edits: edits is List
          ? [
              for (final edit in edits)
                if (edit is Map)
                  ?FileEditRecord.fromJson(edit.cast<String, Object?>()),
            ]
          : const [],
      editsTruncated: json['editsTruncated'] == true,
    );
  }

  static String? _stringOrNull(Object? value) => value is String ? value : null;

  /// This call with the answer it eventually got. [edits] replaces the call's
  /// own when the result recorded better ones; null keeps them.
  ToolActivity withResult({
    String? output,
    bool outputTruncated = false,
    bool isError = false,
    List<FileEditRecord>? edits,
  }) {
    final (kept, cut) = edits == null
        ? (this.edits, editsTruncated)
        : boundedToolEdits(edits);
    return ToolActivity(
      name: name,
      subject: subject,
      imagePath: imagePath,
      output: output,
      outputTruncated: outputTruncated,
      isError: isError,
      plan: plan,
      kind: kind,
      edits: kept,
      editsTruncated: cut,
    );
  }
}

/// The most of one tool result the transcript keeps.
///
/// Results are unbounded — a `Read` of a large file is megabytes — and the
/// transcript file is re-parsed on a two-second poll, so holding every result
/// whole would grow without limit for as long as a session is on screen. The
/// head is what a reader wants; the rest is one click away in the terminal.
///
/// **The number is no longer this file's to choose.** It was 20,000 UTF-16
/// code units while the live stream to the phone and the rows a session stores
/// bounded nothing at all, so the same turn read differently depending on which
/// of the three paths it arrived through — and the one that kept least was the
/// one a reopened session rehydrated from. See [kMaxTranscriptTextBytes].
const int kMaxToolOutputBytes = kMaxTranscriptTextBytes;

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
  for (final key in [...kToolSubjectKeys, ..._mainArgumentKeys]) {
    final value = input[key];
    if (value is String && value.trim().isNotEmpty) {
      return MapEntry(key, value.trim());
    }
  }
  return null;
}

/// Keys an MCP tool's input commonly names its subject by.
const List<String> _mainArgumentKeys = [
  'body',
  'text',
  'title',
  'name',
  'message',
  'id',
  'sessionId',
];

/// The keys whose value is a path to one file, and therefore the only ones that
/// may become an [ToolActivity.imagePath].
///
/// A `command` is not one of them, however it ends: `convert a.png b.png` ends
/// in `.png` and names no single file to draw.
const Set<String> kToolFileKeys = {'file_path', 'notebook_path', 'path'};

/// Builds the activity for a `tool_use`-shaped call.
///
/// A plan tool's input carries none of [kToolSubjectKeys], so `TodoWrite` used
/// to render as the bare word `TodoWrite` — the very "the command is printed
/// twice" complaint this class was written to fix. Its own progress line is the
/// honest subject, and it comes out of the same decode.
ToolActivity toolActivityFor(String name, Object? input) {
  final plan = agentPlanForToolCall(name, input);
  final entry = toolSubjectEntryFor(input);
  final subject = plan?.headline ?? entry?.value;
  final isFile =
      plan == null && entry != null && kToolFileKeys.contains(entry.key);
  final (edits, cut) = boundedToolEdits(
    fileEditsFromToolCall(name: name, input: input),
  );
  return ToolActivity(
    name: name,
    subject: subject,
    imagePath: isFile && looksLikeImagePath(entry.value) ? entry.value : null,
    plan: plan,
    edits: edits,
    editsTruncated: cut,
  );
}

/// [text] cut to [kMaxToolOutputBytes], and whether cutting was needed.
///
/// The tool-output *policy* keeps its name; the cut itself is the one every
/// path shares.
(String, bool) boundedToolOutput(String text) =>
    boundedText(text, maxBytes: kMaxToolOutputBytes);
