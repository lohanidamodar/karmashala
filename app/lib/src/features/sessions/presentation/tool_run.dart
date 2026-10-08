import 'package:agent_cli/stream.dart' show ToolActivity;
import 'package:karmashala_ui/rows.dart' show formatElapsed;

import 'chat_transcript.dart';

/// Where the session's current turn stands, as the view was told. [unknown]
/// falls back to the transcript's own evidence: an unanswered call.
enum TranscriptTurn { unknown, idle, working, awaitingUser }

/// How many rows a live run's fold must take off screen before it is worth a
/// line. Three, because folding two saves one row and costs a click to see
/// either. A settled run ignores it: board N2 folds every finished run to its
/// `Worked for …` line, however short — a turn of three calls drawn as three
/// full cards was the bug (2026-09-28).
const int kToolBatchMinimum = 3;

/// Tools that stop for the user. Pending, each is the row they must answer.
const Set<String> kInteractiveToolNames = {
  'AskUserQuestion',
  'ExitPlanMode',
  'request_user_input',
};

/// Whether this message belongs in a run: a structured tool call. Prose, the
/// user, errors, notices and a tool line with no call behind it all end one.
/// So does a plan, which is drawn as a checklist where it was written, and a
/// plan or questions put to the person, which stay readable once answered.
bool isToolRunMember(ChatMessage message) =>
    message.role == 'tool' &&
    message.tool != null &&
    message.tool!.plan == null &&
    message.tool!.proposedPlan == null &&
    message.tool!.questions.isEmpty;

/// One row of the transcript: a message at [from], or the run of tool calls
/// `[from, to)` folded into one line.
///
/// [pinned] are the run's calls that stay drawn while it is folded — only ever
/// in a live run: a failure, a call awaiting the user, a call the model
/// reasoned its way to — as indices into the same list. [live] marks the
/// trailing run of a turn in progress.
class TranscriptRow {
  const TranscriptRow(
    this.from,
    this.to, {
    this.pinned = const [],
    this.live = false,
    bool? folded,
  }) : folded = folded ?? to - from > 1;

  final int from;
  final int to;
  final List<int> pinned;
  final bool live;

  /// Whether this row is drawn as a fold line rather than its message's own
  /// card. Explicit, not inferred from the length: a settled run of one call
  /// still folds (board N2), and a message row never does.
  final bool folded;

  bool get isBatch => folded;
  int get length => to - from;

  /// What the fold takes off screen, which is what the threshold measures.
  int get hidden => length - pinned.length;
}

/// Groups maximal runs of consecutive tool calls, leaving every other message
/// its own row.
///
/// A settled run always folds, and folds whole: nothing is pinned beneath its
/// line, because a failure is already counted on it (`· 1 failed`), reasoning
/// is one click away in the opened card, and a call nobody answered in a turn
/// that ended is no longer waiting on anyone. Pinning any of those was what
/// kept short finished turns unfolded — one pin on a run of three took it
/// under [kToolBatchMinimum] and every call fell back to a full card.
///
/// The live run keeps its own rules: it folds only when that would hide
/// [kToolBatchMinimum] rows, and a call awaiting the user stays drawn under the
/// line, since that is the row they must answer.
///
/// Pure and linear in [messages]; indices refer to the list it was given.
List<TranscriptRow> transcriptRows(
  List<ChatMessage> messages, {
  TranscriptTurn turn = TranscriptTurn.unknown,
}) {
  final rows = <TranscriptRow>[];
  var i = 0;
  while (i < messages.length) {
    if (!isToolRunMember(messages[i])) {
      rows.add(TranscriptRow(i, i + 1));
      i++;
      continue;
    }
    var end = i;
    var anyPending = false;
    while (end < messages.length && isToolRunMember(messages[end])) {
      anyPending |= messages[end].pending;
      end++;
    }
    final live =
        end == messages.length &&
        switch (turn) {
          TranscriptTurn.working || TranscriptTurn.awaitingUser => true,
          TranscriptTurn.unknown => anyPending,
          TranscriptTurn.idle => false,
        };
    if (!live) {
      rows.add(TranscriptRow(i, end, folded: true));
      i = end;
      continue;
    }
    // The rows that stay drawn at the tail sit under the live line, which is
    // where they come anyway; one earlier in the run splits it there, so
    // nothing is drawn out of order.
    var tail = end;
    while (tail > i && _staysVisible(messages[tail - 1], turn: turn)) {
      tail--;
    }
    var start = i;
    for (var k = i; k < tail; k++) {
      if (!_staysVisible(messages[k], turn: turn)) continue;
      _addSegment(rows, start, k, live: false);
      rows.add(TranscriptRow(k, k + 1));
      start = k + 1;
    }
    _addSegment(
      rows,
      start,
      end,
      live: true,
      pinned: [for (var k = tail; k < end; k++) k],
    );
    i = end;
  }
  return rows;
}

/// Calls `[from, to)` of a live run as one line when that hides
/// [kToolBatchMinimum] rows, else each its own row. [pinned] stay drawn under
/// the line.
void _addSegment(
  List<TranscriptRow> rows,
  int from,
  int to, {
  required bool live,
  List<int> pinned = const [],
}) {
  if (to - from - pinned.length >= kToolBatchMinimum) {
    rows.add(
      live
          ? TranscriptRow(from, to, pinned: pinned, live: true)
          : TranscriptRow(from, to, folded: true),
    );
    return;
  }
  for (var single = from; single < to; single++) {
    rows.add(TranscriptRow(single, single + 1));
  }
}

/// The rows a reader is looking for in a live run. A pending call there is
/// merely running, unless it is a question or plan approval, or the turn is
/// waiting on the user — then it is the approval, and it stays.
bool _staysVisible(ChatMessage message, {required TranscriptTurn turn}) {
  final tool = message.tool!;
  if (tool.isError) return true;
  if (message.thinking != null && message.thinking!.trim().isNotEmpty) {
    return true;
  }
  if (!message.pending) return false;
  if (kInteractiveToolNames.contains(tool.name)) return true;
  return turn == TranscriptTurn.awaitingUser;
}

/// What a call did, as the summary line counts it.
enum ToolKind {
  command,
  read,
  edit,
  patch,
  search,
  webSearch,
  webFetch,
  delegate,
  plan,
  question,
  mcp,
  other,
}

const Map<String, ToolKind> _kindByName = {
  'bash': ToolKind.command,
  'bashoutput': ToolKind.command,
  'killshell': ToolKind.command,
  'powershell': ToolKind.command,
  'shell': ToolKind.command,
  'local_shell': ToolKind.command,
  'exec': ToolKind.command,
  'exec_command': ToolKind.command,
  'write_stdin': ToolKind.command,
  'run_command': ToolKind.command,
  'taskoutput': ToolKind.command,
  'taskstop': ToolKind.command,
  'monitor': ToolKind.command,
  'read': ToolKind.read,
  'notebookread': ToolKind.read,
  'read_file': ToolKind.read,
  'view_file': ToolKind.read,
  'view_image': ToolKind.read,
  'edit': ToolKind.edit,
  'multiedit': ToolKind.edit,
  'write': ToolKind.edit,
  'notebookedit': ToolKind.edit,
  'write_file': ToolKind.edit,
  'write_to_file': ToolKind.edit,
  'edit_file': ToolKind.edit,
  'replace_file_content': ToolKind.edit,
  'apply_patch': ToolKind.patch,
  'grep': ToolKind.search,
  'glob': ToolKind.search,
  'ls': ToolKind.search,
  'grep_search': ToolKind.search,
  'find_by_name': ToolKind.search,
  'list_dir': ToolKind.search,
  'codebase_search': ToolKind.search,
  'file_search': ToolKind.search,
  'websearch': ToolKind.webSearch,
  'web_search': ToolKind.webSearch,
  'search_web': ToolKind.webSearch,
  'webfetch': ToolKind.webFetch,
  'task': ToolKind.delegate,
  'agent': ToolKind.delegate,
  'todowrite': ToolKind.plan,
  'update_plan': ToolKind.plan,
  'askuserquestion': ToolKind.question,
  'exitplanmode': ToolKind.question,
  'request_user_input': ToolKind.question,
  'call_mcp_tool': ToolKind.mcp,
};

/// [name]'s kind, or, for a name we do not know, the agent's own [kind] where
/// its protocol gives one: an ACP call is named by a sentence like
/// `Edit lib/a.dart`.
ToolKind toolKindOf(String name, {String? kind}) {
  if (name.startsWith('mcp__')) return ToolKind.mcp;
  return _kindByName[name.toLowerCase()] ??
      _kindByAcpKind[kind] ??
      ToolKind.other;
}

const Map<String, ToolKind> _kindByAcpKind = {
  'read': ToolKind.read,
  'edit': ToolKind.edit,
  'delete': ToolKind.edit,
  'move': ToolKind.edit,
  'search': ToolKind.search,
  'execute': ToolKind.command,
  'fetch': ToolKind.webFetch,
};

/// `Worked for 2m 12s` — how long a run took, from its first timestamped call
/// to its last. Null when fewer than two calls carry a time, or they span less
/// than a second: a duration nobody recorded is not shown as zero.
String? describeWorkedFor(Iterable<ChatMessage> messages) {
  DateTime? first;
  DateTime? last;
  for (final message in messages) {
    final at = message.at;
    if (at == null) continue;
    if (first == null || at.isBefore(first)) first = at;
    if (last == null || at.isAfter(last)) last = at;
  }
  if (first == null || last == null) return null;
  final span = last.difference(first);
  if (span.inSeconds < 1) return null;
  final minutes = span.inMinutes;
  final seconds = span.inSeconds % 60;
  final hours = span.inHours;
  final text = hours > 0
      ? '${hours}h ${minutes % 60}m'
      : minutes > 0
      ? '${minutes}m ${seconds}s'
      : '${seconds}s';
  return 'Worked for $text';
}

/// Whether [message] is a call that ran a command: Run, Shell, Bash, exec.
bool isCommandCall(ChatMessage message) {
  final tool = message.tool;
  return tool != null &&
      toolKindOf(tool.name, kind: tool.kind) == ToolKind.command;
}

/// How long a finished command took, from its call to its answer. Null while
/// it runs, and when either end went unrecorded.
Duration? commandDuration(ChatMessage message) {
  if (message.pending || !isCommandCall(message)) return null;
  final start = message.at;
  final end = message.tool!.endedAt;
  if (start == null || end == null || end.isBefore(start)) return null;
  return end.difference(start);
}

/// `0.3s`, `2.4s`, `12s`, `1m 12s`: tenths only where they are a tenth of
/// the whole.
String formatCommandDuration(Duration took) {
  final ms = took.inMilliseconds;
  if (ms < 10000) return '${(ms / 1000).toStringAsFixed(1)}s';
  return formatElapsed(took);
}

/// `Ran 8 commands, read 12 files, edited 3 files · 1 failed` — what a run did,
/// by kind, in the order each kind first appeared. Files are counted once each
/// however often they were touched; everything else is counted per call.
String describeToolRun(Iterable<ChatMessage> messages) {
  final calls = <ToolKind, int>{};
  final files = <ToolKind, Set<String>>{};
  final unnamed = <ToolKind, int>{};
  var failed = 0;
  for (final message in messages) {
    final tool = message.tool;
    if (tool == null) continue;
    if (toolCallFailed(message)) failed++;
    final kind = toolKindOf(tool.name, kind: tool.kind);
    calls[kind] = (calls[kind] ?? 0) + 1;
    if (kind != ToolKind.read && kind != ToolKind.edit) continue;
    final subject = tool.subject;
    // A call with no subject is still a file; it just cannot be deduplicated.
    if (subject == null) {
      unnamed[kind] = (unnamed[kind] ?? 0) + 1;
    } else {
      (files[kind] ??= <String>{}).add(subject);
    }
  }
  final onlyOther = calls.length == 1 && calls.containsKey(ToolKind.other);
  final parts = [
    for (final MapEntry(key: kind, value: count) in calls.entries)
      _phrase(
        kind,
        files.containsKey(kind) || unnamed.containsKey(kind)
            ? (files[kind]?.length ?? 0) + (unnamed[kind] ?? 0)
            : count,
        onlyOther: onlyOther,
      ),
  ];
  if (parts.isEmpty) return '';
  final text = parts.join(', ');
  final sentence = text[0].toUpperCase() + text.substring(1);
  return failed == 0 ? sentence : '$sentence · $failed failed';
}

String _phrase(ToolKind kind, int n, {required bool onlyOther}) {
  String counted(String one, String many) => n == 1 ? '1 $one' : '$n $many';
  return switch (kind) {
    ToolKind.command => 'ran ${counted('command', 'commands')}',
    ToolKind.read => 'read ${counted('file', 'files')}',
    ToolKind.edit => 'edited ${counted('file', 'files')}',
    ToolKind.patch => 'applied ${counted('patch', 'patches')}',
    ToolKind.search => 'ran ${counted('search', 'searches')}',
    ToolKind.webSearch => 'ran ${counted('web search', 'web searches')}',
    ToolKind.webFetch => 'fetched ${counted('page', 'pages')}',
    ToolKind.delegate => 'delegated ${counted('task', 'tasks')}',
    ToolKind.plan => n == 1 ? 'updated the plan' : 'updated the plan $n times',
    ToolKind.question => 'asked ${counted('question', 'questions')}',
    ToolKind.mcp => 'called ${counted('MCP tool', 'MCP tools')}',
    ToolKind.other =>
      onlyOther
          ? 'used ${counted('tool', 'tools')}'
          : 'used ${counted('other tool', 'other tools')}',
  };
}

final _exitLine = RegExp(r'^Exit code (-?\d+)$');

/// Whether a call failed: the agent was told so, or its command exited
/// non-zero.
bool toolCallFailed(ChatMessage message) {
  final tool = message.tool;
  if (tool == null) return false;
  if (tool.isError) return true;
  final first = tool.output?.trimLeft().split('\n').first.trim() ?? '';
  final code = _exitLine.firstMatch(first)?[1];
  return code != null && code != '0';
}

/// The most a failure's headline says; the opened card has the rest.
const int kErrorHeadlineChars = 160;

/// A failed call's first words worth reading: `exit 1 · Expected: "/home"`.
/// The `Exit code N` line becomes its prefix; null when the call said nothing.
String? toolErrorHeadline(ToolActivity tool) {
  String? code;
  for (final raw in (tool.output ?? '').split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final exit = _exitLine.firstMatch(line);
    if (exit != null) {
      code ??= exit[1];
      continue;
    }
    final head = line.length > kErrorHeadlineChars
        ? '${line.substring(0, kErrorHeadlineChars - 1)}…'
        : line;
    return code == null ? head : 'exit $code · $head';
  }
  return code == null ? null : 'exit $code';
}

/// The word a call's line opens with, for the kinds named by what they
/// touched; null for those named by the tool itself.
String? toolVerb(ToolKind kind) => switch (kind) {
  ToolKind.command => 'Ran',
  ToolKind.read => 'Read',
  ToolKind.edit => 'Edited',
  ToolKind.patch => 'Patched',
  ToolKind.search => 'Searched',
  ToolKind.webSearch => 'Searched the web',
  ToolKind.webFetch => 'Fetched',
  _ => null,
};

/// Whether a call is a look around — a read or a search — that went fine,
/// so it can share a line with the ones beside it.
bool _isLookup(ChatMessage message) {
  final tool = message.tool;
  if (tool == null || message.pending || toolCallFailed(message)) return false;
  if (tool.edits.isNotEmpty || tool.imagePath != null) return false;
  final kind = toolKindOf(tool.name, kind: tool.kind);
  return kind == ToolKind.read || kind == ToolKind.search;
}

/// Calls `[from, to)` of an opened run as the lines they are drawn on: two or
/// more reads and searches in a row share one, everything else has its own.
/// A run that is all lookups gets a line each: its own line already says it.
List<(int, int)> toolCallLines(List<ChatMessage> messages, int from, int to) {
  final lines = _groupedLines(messages, from, to);
  if (lines.length > 1 || to - from < 2) return lines;
  return [for (var i = from; i < to; i++) (i, i + 1)];
}

List<(int, int)> _groupedLines(List<ChatMessage> messages, int from, int to) {
  final lines = <(int, int)>[];
  var i = from;
  while (i < to) {
    var end = i;
    while (end < to && _isLookup(messages[end])) {
      end++;
    }
    if (end - i >= 2) {
      lines.add((i, end));
      i = end;
    } else {
      lines.add((i, i + 1));
      i++;
    }
  }
  return lines;
}
