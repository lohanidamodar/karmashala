import 'chat_transcript.dart';

/// Where the session's current turn stands, as the view was told. [unknown]
/// falls back to the transcript's own evidence: an unanswered call.
enum TranscriptTurn { unknown, idle, working, awaitingUser }

/// How many rows a fold must take off screen before it is worth a line. Three,
/// because folding two saves one row and costs a click to see either.
const int kToolBatchMinimum = 3;

/// Tools that stop for the user. Pending, each is the row they must answer.
const Set<String> kInteractiveToolNames = {
  'AskUserQuestion',
  'ExitPlanMode',
  'request_user_input',
};

/// Whether this message belongs in a run: a structured tool call. Prose, the
/// user, errors, notices and a tool line with no call behind it all end one.
bool isToolRunMember(ChatMessage message) =>
    message.role == 'tool' && message.tool != null;

/// One row of the transcript: a message at [from], or the run of tool calls
/// `[from, to)` folded into one line.
///
/// [pinned] are the run's calls that stay drawn while it is folded — a failure,
/// a call awaiting the user, a call the model reasoned its way to — as indices
/// into the same list. [live] marks the trailing run of a turn in progress.
class TranscriptRow {
  const TranscriptRow(
    this.from,
    this.to, {
    this.pinned = const [],
    this.live = false,
  });

  final int from;
  final int to;
  final List<int> pinned;
  final bool live;

  bool get isBatch => to - from > 1;
  int get length => to - from;

  /// What the fold takes off screen, which is what the threshold measures.
  int get hidden => length - pinned.length;
}

/// Groups maximal runs of consecutive tool calls, leaving every other message
/// its own row. A run folds only when it would hide [kToolBatchMinimum] rows.
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
    final pinned = <int>[
      for (var k = i; k < end; k++)
        if (_staysVisible(messages[k], live: live, turn: turn)) k,
    ];
    if (end - i - pinned.length >= kToolBatchMinimum) {
      rows.add(TranscriptRow(i, end, pinned: pinned, live: live));
    } else {
      for (var single = i; single < end; single++) {
        rows.add(TranscriptRow(single, single + 1));
      }
    }
    i = end;
  }
  return rows;
}

/// The rows a reader is looking for. A pending call in a settled run was never
/// answered; in a live run it is merely running, unless the turn is waiting on
/// the user — then it is the approval, and all of them stay.
bool _staysVisible(
  ChatMessage message, {
  required bool live,
  required TranscriptTurn turn,
}) {
  final tool = message.tool!;
  if (tool.isError) return true;
  if (message.thinking != null && message.thinking!.trim().isNotEmpty) {
    return true;
  }
  if (!message.pending) return false;
  if (kInteractiveToolNames.contains(tool.name)) return true;
  return !live || turn == TranscriptTurn.awaitingUser;
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

ToolKind toolKindOf(String name) {
  if (name.startsWith('mcp__')) return ToolKind.mcp;
  return _kindByName[name.toLowerCase()] ?? ToolKind.other;
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
    if (tool.isError) failed++;
    final kind = toolKindOf(tool.name);
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
