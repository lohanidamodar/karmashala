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
    this.proposedPlan,
    this.questions = const [],
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

  /// The plan this call asked the person to approve, in the agent's words
  /// (Claude's `ExitPlanMode` input `plan`). Null for every other call.
  final String? proposedPlan;

  /// The questions this call put to the person, each with the answer once
  /// one is known (Claude's `AskUserQuestion`). Empty for every other call.
  final List<AskedQuestion> questions;

  /// The one-line form: what Copy puts on the clipboard, and what the remote
  /// and companion payloads carry. Deliberately the same shape the CLIs print.
  String get summary {
    final s = subject;
    return s == null || s.isEmpty || s == name ? name : '$name($s)';
  }

  /// [output] as a card shows it: an `exit N` line after `Exit code N`,
  /// which only says the code again, is left out.
  String? get shownOutput {
    final text = output;
    if (text == null) return null;
    final lines = text.split('\n');
    final code = RegExp(r'^Exit code (-?\d+)$').firstMatch(lines.first.trim());
    if (code == null) return text;
    final rest = [
      for (final line in lines.skip(1))
        if (line.trim().isNotEmpty) line.trim(),
    ];
    return rest.length == 1 && rest.single.toLowerCase() == 'exit ${code[1]}'
        ? lines.first.trim()
        : text;
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
    'proposedPlan': ?proposedPlan,
    if (questions.isNotEmpty)
      'questions': [for (final q in questions) q.toJson()],
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
      proposedPlan: _stringOrNull(json['proposedPlan']),
      questions: switch (json['questions']) {
        final List<Object?> list => [
          for (final q in list) ?AskedQuestion.fromJson(q),
        ],
        _ => const [],
      },
    );
  }

  static String? _stringOrNull(Object? value) => value is String ? value : null;

  /// This call with the answer it eventually got. [edits] replaces the call's
  /// own when the result recorded better ones; null keeps them. [answers]
  /// (question text to answer) answer [questions]. [imagePath], the image
  /// the result carried, is kept only when the call named none itself.
  ToolActivity withResult({
    String? output,
    bool outputTruncated = false,
    bool isError = false,
    List<FileEditRecord>? edits,
    Map<String, String>? answers,
    String? imagePath,
  }) {
    final (kept, cut) = edits == null
        ? (this.edits, editsTruncated)
        : boundedToolEdits(edits);
    return ToolActivity(
      name: name,
      subject: subject,
      imagePath: this.imagePath ?? imagePath,
      output: output,
      outputTruncated: outputTruncated,
      isError: isError,
      plan: plan,
      kind: kind,
      edits: kept,
      editsTruncated: cut,
      proposedPlan: proposedPlan,
      questions: answers == null
          ? questions
          : [
              for (final q in questions)
                AskedQuestion(
                  question: q.question,
                  answer: answers[q.question] ?? q.answer,
                ),
            ],
    );
  }
}

/// One question a call put to the person, and the answer once known.
class AskedQuestion {
  const AskedQuestion({required this.question, this.answer});

  final String question;
  final String? answer;

  Map<String, Object?> toJson() => {'question': question, 'answer': ?answer};

  static AskedQuestion? fromJson(Object? json) {
    if (json is! Map) return null;
    final question = json['question'];
    if (question is! String) return null;
    final answer = json['answer'];
    return AskedQuestion(
      question: question,
      answer: answer is String ? answer : null,
    );
  }
}

/// The questions a call's [input] asks (`questions[].question`), each with
/// its answer from the input's own `answers` when it carries them.
List<AskedQuestion> askedQuestionsIn(Object? input) {
  if (input is! Map) return const [];
  final questions = input['questions'];
  if (questions is! List) return const [];
  final answers = input['answers'];
  return [
    for (final q in questions)
      if (q is Map && q['question'] is String)
        AskedQuestion(
          question: q['question'] as String,
          answer: answers is Map && answers[q['question']] is String
              ? answers[q['question']] as String
              : null,
        ),
  ];
}

/// A result's `answers` map, as question text to answer; null without one.
Map<String, String>? answersIn(Object? result) {
  if (result is! Map) return null;
  final answers = result['answers'];
  if (answers is! Map) return null;
  return {
    for (final MapEntry(:key, :value) in answers.entries)
      if (key is String && value is String) key: value,
  };
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
  'skill',
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
  final subject = plan?.headline ?? toolSubjectFor(name, input);
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
    proposedPlan: proposedPlanIn(input),
    questions: askedQuestionsIn(input),
  );
}

/// The plan a call's [input] puts to the person for approval: its `plan`.
String? proposedPlanIn(Object? input) => switch (input) {
  {'plan': final String plan} when plan.trim().isNotEmpty => plan,
  _ => null,
};

/// [text] cut to [kMaxToolOutputBytes], and whether cutting was needed.
///
/// The tool-output *policy* keeps its name; the cut itself is the one every
/// path shares.
(String, bool) boundedToolOutput(String text) =>
    boundedText(text, maxBytes: kMaxToolOutputBytes);

/// Web search [results] — maps with a `url` and a `title` — one
/// `title — url` line each.
String webSearchResultLines(Object? results) => [
  if (results is List)
    for (final result in results)
      if (result is Map && result['url'] is String)
        if ((result['url'] as String).trim() case final url when url.isNotEmpty)
          '${switch (result['title']) {
            final String title when title.trim().isNotEmpty => title.trim(),
            _ => url,
          }} — $url',
].join('\n');

/// The identifying line for a call to [name] with [input]: the tools whose
/// input has no one key that says it are named here, the rest by
/// [toolSubjectEntryFor].
String? toolSubjectFor(String name, Object? input) {
  String? field(String key) {
    final value = input is Map ? input[key] : null;
    return value is String && value.trim().isNotEmpty ? value.trim() : null;
  }

  switch (name) {
    // Its `message` is the whole letter; who it went to and what about is
    // the line.
    case 'SendMessage':
      final to = field('to') ?? field('recipient');
      final about =
          field('summary') ?? field('message')?.split('\n').first.trim();
      if (to != null || about != null) {
        return [?to == null ? null : 'to $to', ?about].join(': ');
      }
    case 'TaskStop':
      return field('task_id') ?? field('shell_id');
  }
  return toolSubjectEntryFor(input)?.value;
}
