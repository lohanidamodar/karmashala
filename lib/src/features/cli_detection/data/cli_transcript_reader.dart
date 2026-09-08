import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../agents/domain/agent_ids.dart';
import '../../agents/domain/agent_plan.dart';
import '../../sessions/domain/session_event_types.dart';
import '../../sessions/domain/tool_activity.dart';
import 'subagent_transcript.dart';

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
}

/// Reads a CLI session's full transcript (Claude Code / Codex JSONL) into a flat
/// list of [TranscriptMessage]s, oldest first. Best-effort: malformed lines are
/// skipped and an unreadable file yields an empty list.
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
Future<List<TranscriptMessage>> readCliTranscript(
  String filePath,
  String cli, {
  String? subagentsDirectory,
}) async {
  // Antigravity's own file is a SQLite database whose message columns are
  // protobuf in an unpublished schema, so there is nothing here to parse — see
  // the design note Refused by name rather than
  // left to fail: without this the loop below reads a binary file as UTF-8
  // lines every two seconds behind the imported-session detail pane, and
  // arrives at the same empty list by throwing.
  if (cli == AgentIds.antigravity) return const [];

  final file = File(filePath);
  if (!await file.exists()) return const [];

  final messages = <TranscriptMessage>[];
  // Correlates a result back to the call it answers: Claude Code echoes the
  // `tool_use.id` as `tool_use_id`, Codex echoes `call_id`. Kept for the whole
  // file because the pair is two lines apart at best and a whole turn apart at
  // worst — and an id we never see again simply stays here, costing a string.
  final pending = <String, int>{};
  // Where each `Task` call landed, so the subagent index can be joined on
  // afterwards rather than before. Only `Task` ids: it is the one tool that
  // spawns an agent, and gating on it means a session that never delegated
  // pays nothing at all — not even the `stat` on a directory that is not
  // there.
  final tasks = <String, int>{};
  // The background-subagent ledger: agent id → the row of the `Agent` call
  // that launched it. Two maps because a boundary holds every entry aside and
  // takes back only the ones the CLI names again — see
  // [TranscriptMessage.pendingBackgroundAgentId].
  final background = <String, int>{};
  final acrossBoundary = <String, int>{};
  try {
    await for (final line
        in file
            .openRead()
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (line.isEmpty) continue;
      final Object? decoded;
      try {
        decoded = jsonDecode(line);
      } on FormatException {
        continue;
      }
      if (decoded is! Map<String, dynamic>) continue;
      // Read once per line and handed down: both CLIs carry it in the same
      // place, and every message the line produces was written at that instant.
      final at = _lineTimestamp(decoded);
      // Claude's shape is the default: it is the least-wrong guess for an
      // agent we have no reader for.
      if (cli == AgentIds.codex) {
        _parseCodexLine(decoded, messages, pending, at);
      } else {
        _parseClaudeLine(
          decoded,
          messages,
          pending,
          tasks,
          background,
          acrossBoundary,
          at,
        );
      }
    }
  } catch (_) {
    // Truncated/locked file — return whatever parsed.
  }
  await _attachSubagents(messages, tasks, filePath, subagentsDirectory);
  // After the join, because that one rebuilds the very rows this stamps.
  _stampBackgroundAgents(messages, background);
  return messages;
}

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
    );
  });
}

/// The instant a transcript line was written, or null when it carried none.
///
/// The same key in both formats. `toUtc()` because a `Z`-suffixed instant
/// already is one and anything else would compare against a UTC clock wrongly.
DateTime? _lineTimestamp(Map<String, dynamic> json) {
  final raw = json['timestamp'];
  if (raw is! String) return null;
  return DateTime.tryParse(raw)?.toUtc();
}

/// One subagent's own turns, in the same shape as its parent's.
///
/// Read only when a row is expanded. The directory it sits in is also the
/// index for anything *it* delegated, so a depth-2 agent joins the same way.
Future<List<TranscriptMessage>> readSubagentTranscript(String filePath) =>
    readCliTranscript(
      filePath,
      AgentIds.claudeCode,
      subagentsDirectory: p.dirname(filePath),
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
) {
  final payload = json['payload'];
  if (payload is! Map) return;
  switch (payload['type']) {
    case 'message':
      _parseCodexMessage(payload, out, at);
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
) {
  final role = payload['role'] == 'user' ? 'user' : 'agent';
  final content = payload['content'];
  if (content is String) {
    _add(out, role, content, at);
    return;
  }
  if (content is! List) return;
  for (final block in content) {
    if (block is! Map) continue;
    final t = block['type'];
    if (t == 'input_text' || t == 'output_text' || t == 'text') {
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
  );
}

void _add(List<TranscriptMessage> out, String role, Object? text, DateTime? at) {
  if (text is! String) return;
  final trimmed = text.trim();
  if (trimmed.isEmpty) return;
  out.add(TranscriptMessage(role: role, text: trimmed, at: at));
}
