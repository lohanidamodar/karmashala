import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../util/bounded_lines.dart';
import '../../util/bounded_text.dart';
import '../../agents/adapter/agent_transcripts.dart';
import '../../agents/adapter/injected_context.dart';
import '../../agents/domain/agent_registry.dart';
import '../../agents/domain/agent_plan.dart';
import '../../sessions/session_event_types.dart';
import '../../sessions/tool_activity.dart';
import './transcript_dialect.dart';
import './subagent_transcript.dart';

part 'cli_transcript_tail.dart';
part 'cli_transcript_turns.dart';

/// The compaction the CLI ran immediately before the row that carries this.
///
/// A real boundary record on this machine is `type: system` with
/// `subtype: compact_boundary`, `parentUuid: null`, a `logicalParentUuid`
/// naming the pre-compaction tail, and a `compactMetadata` — the conversation's
/// DAG is cut there deliberately. Everything before it in the file is history
/// the CLI dropped from its own context and then restated as the summary that
/// follows, so a reader walking the file linearly shows the history, then a
/// summary of it, then the continuation.
///
/// **Measured rather than assumed.** `readCliTranscript` over a real compacted
/// transcript here returns **2,793 rows across two boundaries**: row 1,287 is a
/// 17,795-character `user` row restating the 1,287 before it, and row 2,556 is
/// a 21,070-character one restating everything up to there. In the chat view
/// both are drawn as the *user's* own turn.
///
/// This marks **where** the cut is and decides nothing else. The list
/// `readCliTranscript` returns keeps its length, order, roles and text, so the
/// conversation index still holds every pre-compaction turn and search still
/// finds them; only the renderer collapses.
class CompactionBoundary {
  const CompactionBoundary({this.trigger});

  /// `auto` when the context filled, `manual` for `/compact`, and null when the
  /// record did not say. Never inferred from anything else.
  final String? trigger;

  Map<String, Object?> toJson() => {'trigger': ?trigger};

  static CompactionBoundary fromJson(Map<String, Object?> json) {
    final trigger = json['trigger'];
    return CompactionBoundary(trigger: trigger is String ? trigger : null);
  }

  @override
  String toString() => 'CompactionBoundary(${trigger ?? 'unrecorded'})';
}

/// The role of the row a switched session's transcript holds where another
/// agent took over: its text is what that agent was handed, and its
/// [TranscriptMessage.agentInstallationId] the agent taking over.
const String kAgentSwitchRole = 'agentSwitch';

/// A single message parsed from a CLI session transcript file, normalized to the
/// roles our chat view renders.
class TranscriptMessage {
  const TranscriptMessage({
    required this.role,
    required this.text,
    this.tool,
    this.subagent,
    this.at,
    this.pendingToolUseId,
    this.pendingBackgroundAgentId,
    this.thinking,
    this.compaction,
    this.agentInstallationId,
  });

  /// `user`, `agent`, or `tool`.
  final String role;
  final String text;

  /// Optional model reasoning or thinking process.
  final String? thinking;

  /// The structured call behind a `tool` message: what it ran, and what it
  /// answered. Null for the other two roles.
  final ToolActivity? tool;

  /// The delegated agent a `Task` call spawned — located, not read. Null for
  /// every other row, including a `Task` whose subagent file we cannot find.
  final SubagentRef? subagent;

  /// When the agent wrote this turn, read from the line's own `timestamp`.
  ///
  /// Both shipped CLIs put an ISO-8601 UTC instant on **every** line — Claude
  /// Code at the top level beside `message`, Codex beside `payload` — so a tool
  /// row's [at] is when the call was actually issued, not when we noticed it.
  /// Null for a line that carried none, which is the only honest answer and the
  /// reason nothing downstream may assume an age exists.
  final DateTime? at;

  /// The protocol's own id for a tool call **that has not been answered yet**.
  ///
  /// Set when the `tool_use` is parsed and cleared the moment its `tool_result`
  /// arrives, so this — not `tool.output == null` — is how a caller tells "still
  /// running" from "finished". They are not the same question: a call that
  /// answered with nothing at all lands as a null [ToolActivity.output] too, and
  /// reading that as in-flight would leave it on screen forever.
  final String? pendingToolUseId;

  /// **The CLI's own id for a subagent it is running in the background**, set
  /// only while nothing in this record has reported it finished.
  ///
  /// [pendingToolUseId] cannot answer this: Claude Code answers the parent's
  /// `Agent` call at once with `{"isAsync":true,"status":"async_launched"}` —
  /// 0.2 minutes typically, longest 1.5 across the owner's 518 calls — and
  /// delivers the outcome much later in a `<task-notification>`. A subagent
  /// that ran 76 minutes was therefore never an outstanding call, at any age.
  ///
  /// Three records retire it, each written by the CLI for its own reasons and
  /// each able only to *remove*:
  ///
  /// * a `<task-notification>` naming it as `<task-id>`;
  /// * a `system/compact_boundary`, after which the CLI re-enumerates what is
  ///   still live as `attachment/task_status` rows. **The load-bearing one**:
  ///   95 of 311 background subagents in the owner's largest session never
  ///   reported back at all, and without it all 95 would read as running;
  /// * a `system/agents_killed` — the kill-all gesture.
  ///
  /// Null on every other row, and on a launch with no `agentId`: a launch we
  /// cannot name is one we could never retire.
  final String? pendingBackgroundAgentId;

  /// Set on the **first row after a compaction boundary** — which is the
  /// summary the CLI wrote of everything before it. Null everywhere else. See
  /// [CompactionBoundary].
  final CompactionBoundary? compaction;

  /// The installation that spoke this row, set only in a session that switched
  /// agent; null everywhere else, including every row a file reader returns.
  final String? agentInstallationId;

  /// This row with [agentInstallationId] set.
  TranscriptMessage withAgent(String? installationId) => TranscriptMessage(
    role: role,
    text: text,
    tool: tool,
    subagent: subagent,
    at: at,
    pendingToolUseId: pendingToolUseId,
    pendingBackgroundAgentId: pendingBackgroundAgentId,
    thinking: thinking,
    compaction: compaction,
    agentInstallationId: installationId,
  );

  /// **The wire form a server's transcript page carries** (`sessions.transcript`),
  /// lossless for every field above: lowerCamel names, a null field left out,
  /// [at] as ISO-8601 UTC. A field added to this class is added here too.
  Map<String, Object?> toJson() => {
    'role': role,
    'text': text,
    'thinking': ?thinking,
    'tool': ?tool?.toJson(),
    'subagent': ?subagent?.toJson(),
    'at': ?at?.toUtc().toIso8601String(),
    'pendingToolUseId': ?pendingToolUseId,
    'pendingBackgroundAgentId': ?pendingBackgroundAgentId,
    'compaction': ?compaction?.toJson(),
    'agentInstallationId': ?agentInstallationId,
  };

  /// Reads [toJson]'s form. An unknown field is ignored and a missing or
  /// malformed optional one is null; throws [FormatException] only without
  /// `role` and `text`.
  static TranscriptMessage fromJson(Map<String, Object?> json) {
    final role = json['role'];
    final text = json['text'];
    if (role is! String || text is! String) {
      throw const FormatException('transcript message: no role or text');
    }
    final tool = json['tool'];
    final subagent = json['subagent'];
    final at = json['at'];
    final compaction = json['compaction'];
    String? string(String key) {
      final value = json[key];
      return value is String ? value : null;
    }

    return TranscriptMessage(
      role: role,
      text: text,
      thinking: string('thinking'),
      tool: tool is Map
          ? ToolActivity.fromJson(tool.cast<String, Object?>())
          : null,
      subagent: subagent is Map
          ? SubagentRef.fromJson(subagent.cast<String, Object?>())
          : null,
      at: at is String ? DateTime.tryParse(at)?.toUtc() : null,
      pendingToolUseId: string('pendingToolUseId'),
      pendingBackgroundAgentId: string('pendingBackgroundAgentId'),
      compaction: compaction is Map
          ? CompactionBoundary.fromJson(compaction.cast<String, Object?>())
          : null,
      agentInstallationId: string('agentInstallationId'),
    );
  }
}

/// Reads a CLI session's full transcript (Claude Code / Codex / Antigravity
/// JSONL) into a flat list of [TranscriptMessage]s, oldest first. Best-effort:
/// malformed lines are skipped and an unreadable file yields an empty list.
///
/// A Claude Code `Task` call comes back carrying the [SubagentRef] for the
/// agent it spawned, when one is on disk — see [readSubagentIndexIn]. The
/// delegate's own turns are **not** read here: one session on this machine has
/// 1,485 MiB of them behind a 115 MB parent, and this runs on a two-second
/// poll. [readSubagentTranscript] reads one, when a row is expanded.
///
/// [subagentsDirectory] overrides where that index is looked for. It exists for
/// the nested case: a delegate's transcript already lives *in* the directory
/// that indexes the delegates it spawned in turn.
/// **The file a session's conversation is actually read from**, or null when
/// this agent's store keeps none for it.
///
/// Antigravity's own `conversations/<id>` file is never read as text: its
/// message columns are protobuf in an unpublished schema, and without this
/// redirection [readCliTranscript] would read a binary file as UTF-8 lines
/// every two seconds behind the imported-session detail pane and arrive at an
/// empty list by throwing. What changed on 2026-09-09 is that a **plain JSONL**
/// transcript sits elsewhere in the same store on some installs — see
/// [antigravityTranscriptPathFor], which has the measurement and answers null
/// where the store keeps none, so the old refusal still stands there.
///
/// Exposed rather than inlined because `SessionChatView` asks the same question
/// without reading the file: one rule, so the reading and the read cannot
/// disagree about which file a session's conversation is in.
String? transcriptFileFor(String filePath, String cli) {
  final transcripts = _transcriptsFor(cli);
  return transcripts == null
      ? filePath
      : transcripts.transcriptFileFor(filePath);
}

/// The line format [cli]'s transcripts are parsed with. Claude Code's is the
/// least-wrong guess for an agent that declares none.
TranscriptDialect transcriptDialectFor(String cli) =>
    _transcriptsFor(cli)?.dialect ?? TranscriptDialect.claudeJsonl;

/// A fresh parse of [cli]'s transcript, skipping what its adapter declares
/// nobody said.
_TranscriptParse _parseFor(String cli) => _TranscriptParse(
  transcriptDialectFor(cli),
  _transcriptsFor(cli)?.injected ?? InjectedTranscriptContext.none,
);

/// What [cli]'s adapter says about its transcripts, from the shipped registry
/// — these readers run on worker isolates, where nothing else is reachable.
AgentTranscripts? _transcriptsFor(String cli) =>
    AgentRegistry.builtIn.adapterFor(cli)?.transcripts;

/// [readCliTranscript] on a worker isolate, for a caller that must not stall
/// the one it is on. Measured 2026-09-11: a 136 MB Claude transcript — this
/// machine's largest, one working day — takes 2.5-3.1 s to parse, and the chat
/// view re-reads on every change.
Future<List<TranscriptMessage>> readCliTranscriptOffThread(
  String filePath,
  String cli, {
  String? subagentsDirectory,
}) => Isolate.run(
  () =>
      readCliTranscript(filePath, cli, subagentsDirectory: subagentsDirectory),
);

Future<List<TranscriptMessage>> readCliTranscript(
  String filePath,
  String cli, {
  String? subagentsDirectory,
}) async {
  final path = transcriptFileFor(filePath, cli);
  if (path == null) return const [];
  return _readTranscriptFile(
    path,
    filePath,
    transcriptDialectFor(cli),
    subagentsDirectory,
    injected: _transcriptsFor(cli)?.injected,
  );
}

Future<List<TranscriptMessage>> _readTranscriptFile(
  String path,
  String filePath,
  TranscriptDialect dialect,
  String? subagentsDirectory, {
  InjectedTranscriptContext? injected,
}) async {
  final file = File(path);
  if (!await file.exists()) return const [];

  final parse = _TranscriptParse(
    dialect,
    injected ?? InjectedTranscriptContext.none,
  );
  try {
    // Bounded rather than `LineSplitter`: a record is materialised whole and
    // `jsonDecode` has no streaming form, so the largest record — not the
    // file — is this reader's peak memory. See [kMaxTranscriptLineBytes].
    await for (final line in boundedLines(file)) {
      parse.add(line);
    }
  } catch (_) {
    // Truncated/locked file — return whatever parsed.
  }
  await _finish(parse.messages, parse, filePath, subagentsDirectory);
  return parse.messages;
}

/// Everything one line of a transcript may need from the lines before it.
///
/// Held as an object rather than as locals of [readCliTranscript] so that a
/// parse can be stopped at a record boundary and resumed when more is appended
/// — see [CliTranscriptTail].
class _TranscriptParse {
  _TranscriptParse(
    this.dialect, [
    this.injected = InjectedTranscriptContext.none,
  ]);

  final TranscriptDialect dialect;
  final InjectedTranscriptContext injected;
  final List<TranscriptMessage> messages = [];
  // Correlates a result back to the call it answers: Claude Code echoes the
  // `tool_use.id` as `tool_use_id`, Codex echoes `call_id`. Kept for the whole
  // file because the pair is two lines apart at best and a whole turn apart at
  // worst — and an id we never see again simply stays here, costing a string.
  final Map<String, int> pending = {};
  // Where each `Task` call landed, so the subagent index can be joined on
  // afterwards rather than before. Only `Task` ids: it is the one tool that
  // spawns an agent, and gating on it means a session that never delegated
  // pays nothing at all — not even the `stat` on a directory that is not
  // there.
  final Map<String, int> tasks = {};
  // The background-subagent ledger: agent id → the row of the `Agent` call
  // that launched it. Two maps because a boundary holds every entry aside and
  // takes back only the ones the CLI names again — see
  // [TranscriptMessage.pendingBackgroundAgentId].
  final Map<String, int> background = {};
  final Map<String, int> acrossBoundary = {};
  // The boundary whose summary has not been reached yet. Held here rather than
  // returned from `_parseClaudeLine`, because the record that announces a
  // compaction produces no row of its own — the row it belongs to is the next
  // one the file yields, and only this loop can see that happen.
  CompactionBoundary? pendingCompaction;

  /// An independent copy, for a line that may yet be rewritten by the writer.
  _TranscriptParse copy() => _TranscriptParse(dialect, injected)
    ..messages.addAll(messages)
    ..pending.addAll(pending)
    ..tasks.addAll(tasks)
    ..background.addAll(background)
    ..acrossBoundary.addAll(acrossBoundary)
    ..pendingCompaction = pendingCompaction;

  void add(String line) {
    if (line.isEmpty) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, dynamic>) return;
    // Read once per line and handed down: both CLIs carry it in the same
    // place, and every message the line produces was written at that instant.
    final at = _lineTimestamp(decoded);
    // Claude's shape is the default: it is the least-wrong guess for an
    // agent we have no reader for.
    if (dialect == TranscriptDialect.codexRollout) {
      _parseCodexLine(decoded, messages, pending, at, injected);
    } else if (dialect == TranscriptDialect.antigravityJsonl) {
      _parseAntigravityLine(decoded, messages, at);
    } else {
      pendingCompaction = _compactionBoundaryOf(decoded) ?? pendingCompaction;
      final before = messages.length;
      _parseClaudeLine(
        decoded,
        messages,
        pending,
        tasks,
        background,
        acrossBoundary,
        at,
      );
      final boundary = pendingCompaction;
      if (boundary != null && messages.length > before) {
        messages[before] = _withCompaction(messages[before], boundary);
        pendingCompaction = null;
      }
    }
  }
}

/// The joins that need the whole file: applied to [out], which is either
/// [parse]'s own list or a copy of it that [parse] must not see changed.
Future<void> _finish(
  List<TranscriptMessage> out,
  _TranscriptParse parse,
  String filePath,
  String? subagentsDirectory,
) async {
  await _attachSubagents(out, parse.tasks, filePath, subagentsDirectory);
  // After the join, because that one rebuilds the very rows this stamps.
  _stampBackgroundAgents(out, parse.background);
}

/// The compaction [json] announces, or null for every other line.
///
/// Gated on `compactMetadata` as well as the subtype: `type: system` is the
/// CLI's own catch-all — `agents_killed` arrives the same way — and the
/// metadata is the field only a real boundary carries.
CompactionBoundary? _compactionBoundaryOf(Map<String, dynamic> json) {
  if (json['type'] != 'system') return null;
  if (json['subtype'] != 'compact_boundary') return null;
  final metadata = json['compactMetadata'];
  if (metadata is! Map) return null;
  final trigger = metadata['trigger'];
  return CompactionBoundary(trigger: trigger is String ? trigger : null);
}

/// [row] again, carrying the boundary it follows. One row per compaction.
TranscriptMessage _withCompaction(
  TranscriptMessage row,
  CompactionBoundary boundary,
) => TranscriptMessage(
  role: row.role,
  text: row.text,
  tool: row.tool,
  subagent: row.subagent,
  at: row.at,
  pendingToolUseId: row.pendingToolUseId,
  pendingBackgroundAgentId: row.pendingBackgroundAgentId,
  thinking: row.thinking,
  compaction: boundary,
);

/// Marks the calls whose background subagents nothing has reported finished.
///
/// Once at the end rather than as the ledger moves: a boundary can retire an
/// entry recorded thousands of lines earlier. Only the survivors are rewritten
/// — 4 rows on the owner's live session, not the 30,000 the file holds.
void _stampBackgroundAgents(
  List<TranscriptMessage> messages,
  Map<String, int> background,
) {
  background.forEach((agentId, index) {
    if (index >= messages.length) return;
    final row = messages[index];
    messages[index] = TranscriptMessage(
      role: row.role,
      text: row.text,
      tool: row.tool,
      subagent: row.subagent,
      at: row.at,
      pendingToolUseId: row.pendingToolUseId,
      pendingBackgroundAgentId: agentId,
      thinking: row.thinking,
      compaction: row.compaction,
    );
  });
}

/// Hangs each located subagent on the `Task` row that spawned it.
///
/// Runs after the parse, not before, so the directory is read only for a
/// transcript that actually delegated. A `Task` with nothing to join keeps the
/// row it already had, byte for byte.
Future<void> _attachSubagents(
  List<TranscriptMessage> messages,
  Map<String, int> tasks,
  String filePath,
  String? subagentsDirectory,
) async {
  if (tasks.isEmpty) return;
  final index = await readSubagentIndexIn(
    subagentsDirectory ?? subagentsDirectoryFor(filePath),
  );
  if (index.isEmpty) return;
  tasks.forEach((id, position) {
    final reference = index[id];
    if (reference == null || position >= messages.length) return;
    final row = messages[position];
    messages[position] = TranscriptMessage(
      role: row.role,
      text: row.text,
      tool: row.tool,
      subagent: reference,
      at: row.at,
      pendingToolUseId: row.pendingToolUseId,
      compaction: row.compaction,
    );
  });
}

/// One line of an Antigravity `transcript.jsonl`, in the roles the chat view
/// renders.
///
/// **The format, surveyed over the 25 conversations on this machine's WSL
/// install — 4,846 lines, 2026-09-09.** Every line carries `step_index`,
/// `source`, `type`, `status` and `created_at`; `content`, `tool_calls`,
/// `thinking` and `truncated_fields` are optional.
///
/// | `type` | `source` | Lines | What it is |
/// | --- | --- | --- | --- |
/// | `PLANNER_RESPONSE` | `MODEL` | 2,383 | the model's turn |
/// | `GENERIC` | `MODEL` | 2,266 | the result of the call above it |
/// | `SYSTEM_MESSAGE` | `SYSTEM` | 127 | injected context, not a turn |
/// | `USER_INPUT` | `USER_EXPLICIT` | 52 | what the user typed |
/// | `CHECKPOINT` | `SYSTEM` | 14 | the CLI's own compaction summary |
/// | `ERROR_MESSAGE` | `SYSTEM` | 4 | a run that broke |
///
/// **A result is joined to the call immediately above it, because the file
/// offers nothing else.** There is no call id anywhere in it. All 2,310 records
/// that carry `tool_calls` carry exactly one, and 2,261 are followed straight
/// away by the `GENERIC` answering it — the other 49 are calls whose result
/// never landed, which is what an interrupted run leaves behind. Only 5 of the
/// 2,266 `GENERIC` records have no call above them at all, and those become a
/// row of their own rather than being attached to whatever happened to be last.
///
/// **`SYSTEM`-sourced records render nothing**, the same rule `_parseClaudeLine`
/// applies to its own `type: system` lines: they are session-level records
/// rather than turns.
///
/// **`thinking` is filled, and it rides on the first row the record produces.**
/// 435 of the same 4,846 lines carry the field, every one a `PLANNER_RESPONSE`
/// with `status: DONE`, mean 1,043 characters and longest 4,121. Only **9** of
/// them also carry `content`, so hanging it on the text row alone would show 9
/// of 435; **425** carry `tool_calls` and no text, which is the model reasoning
/// its way to a call, and the last **1** carries neither and is the one block
/// dropped. 26 arrive already cut by the CLI, which says so in
/// `truncated_fields`.
///
/// **Nothing here creates a row to carry it**, which is what leaves the
/// conversation index where it was: `ConversationIndexer` reads `text` off the
/// `kIndexedTranscriptRoles` rows and never `thinking`, so a filled block moves
/// neither the rows the index holds nor their ordinals. That file states the
/// invariant; `thinking_is_not_indexed_test.dart` measures it.
void _parseAntigravityLine(
  Map<String, dynamic> json,
  List<TranscriptMessage> out,
  DateTime? at,
) {
  final content = json['content'];
  switch (json['type']) {
    case 'USER_INPUT':
      _add(out, 'user', _cleanAntigravityUserInput(content), at);
    case 'PLANNER_RESPONSE':
      // Held across the rows this record makes and spent on the first of them.
      var thinking = _antigravityThinking(json['thinking']);
      final before = out.length;
      _add(out, 'agent', content, at, thinking: thinking);
      if (out.length > before) thinking = null;
      final calls = json['tool_calls'];
      if (calls is! List) return;
      for (final call in calls) {
        if (call is! Map) continue;
        final name = call['name'];
        if (name is! String) continue;
        final args = call['args'];
        // The same shape `toolActivityFor` builds, with this CLI's own key for
        // the identifying line. `kToolSubjectKeys` is Claude's snake_case set
        // and matches none of Antigravity's, which would leave every row
        // reading as the bare tool name; `toolSummary` is the CLI's own words
        // and is on all 2,310 calls in the store here.
        final plan = agentPlanForToolCall(name, args);
        final activity = ToolActivity(
          name: name,
          subject: plan?.headline ?? _antigravityArg(args, 'toolSummary'),
          plan: plan,
        );
        out.add(
          TranscriptMessage(
            role: 'tool',
            text: activity.summary,
            tool: activity,
            at: at,
            thinking: thinking,
            // `status` rather than the absence of a result: a call the file
            // says is `RUNNING` is the one still in flight, and the 49 calls
            // whose result never arrived belong to finished runs we cannot
            // report on — not to work happening now.
            pendingToolUseId: json['status'] == 'RUNNING'
                ? '${json['step_index']}'
                : null,
          ),
        );
        thinking = null;
      }
    case 'GENERIC':
      if (content is! String || content.trim().isEmpty) return;
      final last = out.isEmpty ? null : out.last;
      if (last?.tool != null && last!.tool!.output == null) {
        _attachAntigravityResult(out, content);
        return;
      }
      _add(out, 'tool', content, at);
  }
}

/// Extracts the user's prompt from `<USER_REQUEST>...</USER_REQUEST>` if present.
///
/// Headless and interactive prompts in Antigravity transcripts are often wrapped
/// in `<USER_REQUEST>` delimiters when additional metadata or context summaries
/// are prepended to the prompt.
Object? _cleanAntigravityUserInput(Object? content) {
  if (content is! String) return content;
  final match = RegExp(
    r'<USER_REQUEST>([\s\S]*?)</USER_REQUEST>',
  ).firstMatch(content);
  if (match != null) {
    final extracted = match.group(1)?.trim();
    if (extracted != null && extracted.isNotEmpty) {
      return extracted;
    }
  }
  return content;
}

/// The reasoning a record carried, or null when it carried none.
///
/// Plain text, not the protojson [_antigravityArg] has to unwrap — the field
/// sits beside `content` on the record itself rather than inside a call's
/// `args`. Bounded like a turn: the CLI truncates its own long blocks and says
/// so, but nothing promises it always will.
String? _antigravityThinking(Object? raw) {
  if (raw is! String) return null;
  final text = raw.trim();
  return text.isEmpty ? null : boundedText(text).$1;
}

/// One `args` value as plain text, or null when it holds none.
///
/// The map is protojson and its string values arrive **JSON-encoded**: 8,513 of
/// the 12,175 values in this machine's store are wrapped in quotes and the
/// other 3,662 are bare booleans and numbers. Reading one raw prints the quotes
/// with it.
String? _antigravityArg(Object? args, String key) {
  if (args is! Map) return null;
  final raw = args[key];
  if (raw is! String) return null;
  var value = raw;
  if (raw.length > 1 && raw.startsWith('"') && raw.endsWith('"')) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is String) value = decoded;
    } on FormatException {
      // Not encoded after all; the raw text is the best answer there is.
    }
  }
  final text = value.trim();
  return text.isEmpty ? null : text;
}

/// Hangs a `GENERIC` result on the call row directly above it.
///
/// By position, and only ever the last row — see [_parseAntigravityLine] for
/// the counts that make that the file's own rule rather than a guess.
void _attachAntigravityResult(List<TranscriptMessage> out, String output) {
  final index = out.length - 1;
  final row = out[index];
  final (bounded, truncated) = boundedToolOutput(output.trimRight());
  out[index] = TranscriptMessage(
    role: row.role,
    text: row.text,
    tool: row.tool!.withResult(
      output: bounded.isEmpty ? null : bounded,
      outputTruncated: truncated,
      isError: false,
    ),
    at: row.at,
    // Carried through: 2,261 of the 2,310 calls here are answered by the very
    // next line, so dropping it would lose the reasoning on almost every one.
    thinking: row.thinking,
    compaction: row.compaction,
  );
}

/// The instant a transcript line was written, or null when it carried none.
///
/// One key for Claude Code and Codex, which both write `timestamp`, and
/// `created_at` for Antigravity, which writes the same ISO-8601 instant under
/// its own name. `toUtc()` because a `Z`-suffixed instant already is one and
/// anything else would compare against a UTC clock wrongly.
DateTime? _lineTimestamp(Map<String, dynamic> json) {
  final raw = json['timestamp'] ?? json['created_at'];
  if (raw is! String) return null;
  return DateTime.tryParse(raw)?.toUtc();
}

/// One subagent's own turns, in the same shape as its parent's.
///
/// Read only when a row is expanded. The directory it sits in is also the
/// index for anything *it* delegated, so a depth-2 agent joins the same way.
Future<List<TranscriptMessage>> readSubagentTranscript(String filePath) =>
    _readTranscriptFile(
      filePath,
      filePath,
      TranscriptDialect.claudeJsonl,
      p.dirname(filePath),
    );

void _parseClaudeLine(
  Map<String, dynamic> json,
  List<TranscriptMessage> out,
  Map<String, int> pending,
  Map<String, int> tasks,
  Map<String, int> background,
  Map<String, int> acrossBoundary,
  DateTime? at,
) {
  final type = json['type'];
  // Session-level records: not turns, so they render nothing, but they are the
  // only thing that can retire a subagent nobody ever reported.
  if (type == 'system') {
    switch (json['subtype']) {
      // The `task_status` rows that follow re-state what is still live.
      case 'compact_boundary':
        acrossBoundary.addAll(background);
        background.clear();
      // The kill-all gesture: nothing survives it, named or not.
      case 'agents_killed':
        background.clear();
        acrossBoundary.clear();
    }
    return;
  }
  if (type == 'attachment') {
    final attachment = json['attachment'];
    if (attachment is! Map) return;
    // An envelope that arrived mid-turn is queued, not a user turn.
    if (attachment['type'] == 'queued_command') {
      _retireReportedAgents(attachment['prompt'], background, acrossBoundary);
      return;
    }
    if (attachment['type'] != 'task_status') return;
    if (attachment['status'] != 'running') return;
    final id = attachment['taskId'];
    // Only an agent we watched launch: a re-statement with no launch record
    // behind it carries no instant to count an age from.
    if (id is String) {
      final row = acrossBoundary.remove(id);
      if (row != null) background[id] = row;
    }
    return;
  }
  if (type != 'user' && type != 'assistant') return;
  final message = json['message'];
  if (message is! Map) return;
  final content = message['content'];
  final role = type == 'user' ? 'user' : 'agent';
  if (role == 'user' && (background.isNotEmpty || acrossBoundary.isNotEmpty)) {
    _retireReportedAgents(content, background, acrossBoundary);
  }

  if (content is String) {
    _add(out, role, content, at);
    return;
  }
  if (content is! List) return;
  for (final part in content) {
    if (part is String) {
      _add(out, role, part, at);
    } else if (part is Map) {
      switch (part['type']) {
        case 'text':
          _add(out, role, part['text'], at);
        case 'tool_use':
          final name = part['name'];
          if (name is String) {
            final activity = toolActivityFor(name, part['input']);
            final id = part['id'];
            if (id is String) {
              pending[id] = out.length;
              if (isSubagentToolName(name)) tasks[id] = out.length;
            }
            out.add(
              TranscriptMessage(
                role: 'tool',
                text: activity.summary,
                tool: activity,
                at: at,
                pendingToolUseId: id is String ? id : null,
              ),
            );
          }
        case 'tool_result':
          // Read before `_attachResult` takes the id out of `pending`: the
          // launch and the row it belongs to are known only here.
          final id = part['tool_use_id'];
          final row = id is String ? pending[id] : null;
          _attachResult(
            out,
            pending,
            id: id,
            output: _claudeResultText(part['content']),
            isError: part['is_error'] == true,
          );
          final launched = _asyncAgentId(json['toolUseResult']);
          if (launched != null && row != null) background[launched] = row;
      }
    }
  }
}

/// The agent id a `toolUseResult` says went to the background, or null.
///
/// `isAsync` rather than the `status` word: `async_launched` is the only value
/// the owner's 311 launches carry, and gating on a string the CLI could extend
/// would silently stop seeing a subagent the day it did.
String? _asyncAgentId(Object? toolUseResult) {
  if (toolUseResult is! Map) return null;
  if (toolUseResult['isAsync'] != true) return null;
  final id = toolUseResult['agentId'];
  return id is String && id.isNotEmpty ? id : null;
}

/// Drops from the ledger every background agent [content] reports back on.
///
/// Joined on `<task-id>`, not the `<tool-use-id>` beside it: the ledger is
/// keyed by agent id, and 151 of 908 envelopes in the owner's store carry no
/// tool-use-id at all. The `<status>` word is not read — completed, failed,
/// killed and stopped are four things to say and one thing to know.
void _retireReportedAgents(
  Object? content,
  Map<String, int> background,
  Map<String, int> acrossBoundary,
) {
  // Per block, so an ordinary turn costs one `contains` and no allocation.
  for (final block in content is List ? content : [content]) {
    final String text;
    if (block is String) {
      text = block;
    } else if (block is Map && block['text'] is String) {
      text = block['text'] as String;
    } else {
      continue;
    }
    if (!text.contains(_taskNotificationMarker)) continue;
    for (final match in _taskIdPattern.allMatches(text)) {
      final id = match.group(1);
      background.remove(id);
      acrossBoundary.remove(id);
    }
  }
}

/// The wrapper a background task's outcome arrives in, as the parent's own turn.
const String _taskNotificationMarker = '<task-notification>';

/// Compiled once for the process: this runs on every user turn of every parse.
final RegExp _taskIdPattern = RegExp(r'<task-id>([^<]*)</task-id>');

/// The text of a Claude `tool_result`'s content.
///
/// `image` blocks are read for their existence and then dropped: their `data`
/// is a base64 copy of the file, one real transcript carried 96 of them, and
/// the picture is drawn from the path on disk instead
/// (`TranscriptImagePreview`).
String _claudeResultText(Object? content) {
  if (content is String) return content;
  if (content is! List) return '';
  final parts = <String>[];
  for (final block in content) {
    if (block is Map && block['type'] == 'text' && block['text'] is String) {
      parts.add(block['text'] as String);
    }
  }
  return parts.join('\n');
}

void _parseCodexLine(
  Map<String, dynamic> json,
  List<TranscriptMessage> out,
  Map<String, int> pending,
  DateTime? at,
  InjectedTranscriptContext injected,
) {
  final payload = json['payload'];
  if (payload is! Map) return;
  switch (payload['type']) {
    case 'message':
      _parseCodexMessage(payload, out, at, injected);
    // Codex names its shell differently depending on the tool surface —
    // `function_call` for the classic `shell`, `custom_tool_call` for the
    // `exec` sandbox — but both carry a name, a `call_id` and an answer.
    case 'function_call':
    case 'custom_tool_call':
      final name = payload['name'];
      if (name is! String) return;
      // `arguments` is a JSON *string* for Codex, which is why the plan reader
      // takes either — see [AgentPlanSupport.planIn]. Its headline is a better
      // subject than the fallback below, which for `update_plan` was the whole
      // argument blob on one line.
      final plan = agentPlanForToolCall(name, payload['arguments']);
      final activity = ToolActivity(
        name: name,
        subject: plan?.headline ?? _codexSubject(payload),
        plan: plan,
      );
      final callId = payload['call_id'];
      if (callId is String) pending[callId] = out.length;
      out.add(
        TranscriptMessage(
          role: 'tool',
          text: activity.summary,
          tool: activity,
          at: at,
          pendingToolUseId: callId is String ? callId : null,
        ),
      );
    case 'function_call_output':
    case 'custom_tool_call_output':
      _attachResult(
        out,
        pending,
        id: payload['call_id'],
        output: _codexResultText(payload['output']),
        isError: false,
      );
  }
}

void _parseCodexMessage(
  Map<dynamic, dynamic> payload,
  List<TranscriptMessage> out,
  DateTime? at,
  InjectedTranscriptContext injected,
) {
  final said = payload['role'];
  final role = said == 'user' ? 'user' : 'agent';
  bool skipped(Object? text) =>
      text is String && injected.isInjected(said is String ? said : null, text);
  final content = payload['content'];
  if (content is String) {
    if (!skipped(content)) _add(out, role, content, at);
    return;
  }
  if (content is! List) return;
  for (final block in content) {
    if (block is! Map) continue;
    final t = block['type'];
    if ((t == 'input_text' || t == 'output_text' || t == 'text') &&
        !skipped(block['text'])) {
      _add(out, role, block['text'], at);
    }
  }
}

/// The identifying line of a Codex call.
///
/// `shell` sends `arguments` as a JSON string holding `command` as an argv
/// list, which is the clean case; `exec` sends `input` as a snippet of the
/// script it is about to run, of which the first line is the honest summary.
String? _codexSubject(Map<dynamic, dynamic> payload) {
  final input = payload['input'];
  if (input is String && input.trim().isNotEmpty) {
    return input.trim().split('\n').first;
  }
  final arguments = payload['arguments'];
  if (arguments is! String || arguments.trim().isEmpty) return null;
  try {
    final decoded = jsonDecode(arguments);
    if (decoded is Map) {
      final command = decoded['command'];
      if (command is List) return command.join(' ');
      if (command is String) return command;
      final entry = toolSubjectEntryFor(decoded);
      if (entry != null) return entry.value;
    }
  } on FormatException {
    // Arguments we cannot read are still better shown than hidden.
  }
  return arguments.trim().split('\n').first;
}

/// The text of a Codex call's output, which is either a string or the same
/// `input_text` blocks its messages use.
String _codexResultText(Object? output) {
  if (output is String) return output;
  if (output is! List) return '';
  final parts = <String>[];
  for (final block in output) {
    if (block is Map && block['text'] is String) {
      parts.add(block['text'] as String);
    }
  }
  return parts.join();
}

/// Hangs a result on the call it answers, or drops it when that call is not in
/// this file — a transcript read while it is being written ends mid-pair.
void _attachResult(
  List<TranscriptMessage> out,
  Map<String, int> pending, {
  required Object? id,
  required String output,
  required bool isError,
}) {
  if (id is! String) return;
  final index = pending.remove(id);
  if (index == null || index >= out.length) return;
  final call = out[index].tool;
  if (call == null) return;
  final trimmed = output.trimRight();
  final (bounded, truncated) = boundedToolOutput(trimmed);
  final row = out[index];
  out[index] = TranscriptMessage(
    role: row.role,
    text: row.text,
    tool: call.withResult(
      output: bounded.isEmpty ? null : bounded,
      outputTruncated: truncated,
      isError: isError,
    ),
    subagent: row.subagent,
    // Answered, so it is no longer outstanding — and this is the only place
    // that may say so. A result whose text was empty leaves `output` null, so
    // dropping the id here is what keeps the call from looking in-flight
    // forever.
    at: row.at,
    compaction: row.compaction,
  );
}

void _add(
  List<TranscriptMessage> out,
  String role,
  Object? text,
  DateTime? at, {
  String? thinking,
}) {
  if (text is! String) return;
  final trimmed = text.trim();
  if (trimmed.isEmpty) return;
  // Bounded here, not only on the tool result beside it. A tool row never
  // reaches the phone — the wire drops it — so a turn is the payload that
  // actually crosses, and leaving it whole meant rehydration could restore
  // text the live stream had already trimmed.
  out.add(
    TranscriptMessage(
      role: role,
      text: boundedText(trimmed).$1,
      at: at,
      thinking: thinking,
    ),
  );
}
