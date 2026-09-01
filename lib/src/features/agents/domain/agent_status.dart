/// What an agent is doing right now, as far as any status source can tell.
///
/// [unknown] is a first-class state, not an error: most agents sit there until
/// hooks are installed or a state file can be classified. Nothing in the status
/// pipeline throws to express "we don't know".
enum AgentActivityStatus { idle, working, awaitingApproval, failed, unknown }

/// Which source produced a status report.
enum AgentStatusSource {
  /// A callback from a hook installed into the agent's own config.
  hook,

  /// The agent's session/state file on disk.
  stateFile,

  /// The rendered bottom of the agent's own terminal screen.
  terminalGrid,

  /// Nothing could tell us anything.
  none,
}

/// What an agent that has stopped for the user is actually waiting on.
///
/// [AgentActivityStatus.awaitingApproval] answers "is this session holding the
/// user up" — the question the badge ("Needs you"), the tray and the
/// notification reasons already ask of it. It does **not** answer "is a prompt
/// open", and the two are not the same question. Claude Code fires one
/// `Notification` hook both when it wants permission and when it has merely
/// finished a turn and is sitting at its own input; the app read every one of
/// them as an approval and offered an Approve button that types Enter. At an
/// idle prompt Enter submits whatever is in the composer, so the misread turned
/// a passive notice into a keystroke in the user's live agent.
///
/// This is the axis that separates them, and only [approval] may ever be
/// answered on the user's behalf.
enum AgentWaitKind {
  /// A prompt with options is open, and the agent named the keys that answer
  /// it. Approve/Deny mean something here.
  approval,

  /// The agent is at its own input with nothing to confirm — it finished its
  /// turn, or it is nudging about a message it already posted.
  input,

  /// No source could tell which. Treated exactly like [input] where it matters:
  /// a key we are not sure lands on a prompt is a key we do not send.
  unrecorded,
}

/// One observation of an agent session's status.
class AgentStatusReport {
  const AgentStatusReport({
    required this.agentId,
    required this.sessionId,
    required this.status,
    required this.observedAt,
    required this.source,
    this.detail,
    this.sourceModifiedAt,
    this.evidence = const [],
    this.waiting = AgentWaitKind.unrecorded,
  });

  /// Registry id of the agent (`AgentDescriptor.id`).
  final String agentId;

  /// The CLI's own session id — the key both sources share.
  final String sessionId;

  final AgentActivityStatus status;
  final AgentStatusSource source;

  /// When **we** looked. Always now-ish, and therefore says nothing about how
  /// current the answer is.
  final DateTime observedAt;

  /// When the thing this status was read *from* was last written, for a source
  /// that can tell — today, the transcript file's mtime. Null for the others.
  final DateTime? sourceModifiedAt;

  /// When the thing this status was read *from* was last written.
  ///
  /// The distinction is the whole point of showing an age. A poll timestamp is
  /// always fresh and would make a three-day-old transcript look live; the
  /// file's own modification time is the number that tells a reader how much to
  /// trust the word beside it.
  ///
  /// Falls back to [observedAt] for sources that are live by construction — a
  /// hook callback and a rendered terminal screen are both evidence produced at
  /// the moment we read them.
  DateTime get evidenceAt => sourceModifiedAt ?? observedAt;

  /// Why the source concluded this (hook event name, matched record value, …).
  ///
  /// The *matcher*, not the match: for the grid source this is the substring
  /// that fired, which is a breadcrumb for a tooltip and never a description of
  /// what the agent wants.
  final String? detail;

  /// The agent's own words, verbatim, when the source carried any: the rendered
  /// rows of its prompt, or a hook payload's message.
  ///
  /// Empty is the normal case and must be rendered as "we do not know", never
  /// smoothed over. This is the whole difference between telling a user their
  /// agent is blocked and telling them what on. Nothing here is ever
  /// synthesised — a source that cannot quote the agent contributes nothing.
  final List<String> evidence;

  /// What the agent is waiting on, when the source could tell.
  ///
  /// Defaults to [AgentWaitKind.unrecorded] because most sources cannot tell: a
  /// transcript records what was said, never that a modal is on screen. Only a
  /// source with positive evidence — a rendered prompt, or a hook message the
  /// agent's descriptor recognises — may claim [AgentWaitKind.approval].
  final AgentWaitKind waiting;

  @override
  String toString() =>
      'AgentStatusReport($agentId/$sessionId, ${status.name}, ${source.name}, '
      '${waiting.name})';
}

/// What to ask the status service about.
class AgentStatusQuery {
  const AgentStatusQuery({
    required this.agentId,
    required this.sessionId,
    this.stateFilePath,
    this.terminalTailLines = const [],
  });

  final String agentId;
  final String sessionId;

  /// The session transcript's path, as already known from CLI detection or an
  /// imported session. `null` when we have no file to read.
  final String? stateFilePath;

  /// The rendered bottom rows of the pane this session runs in, when it runs in
  /// one. Empty for a session with no terminal — an imported CLI session, or one
  /// launched into somebody else's terminal window — which is the honest input
  /// for "we cannot see its screen".
  final List<String> terminalTailLines;
}

/// Matches one decoded state-file record by walking [path] into it and
/// comparing the value's string form to [equals].
class StateRecordMatcher {
  const StateRecordMatcher(this.path, this.equals);

  final List<String> path;
  final String equals;

  bool matches(Map<String, Object?> record) {
    Object? value = record;
    for (final segment in path) {
      if (value is! Map) return false;
      value = value[segment];
    }
    return value is String && value == equals;
  }

  @override
  String toString() => '${path.join('.')}=$equals';
}

/// How to classify an agent's state file. All matcher lists are evaluated
/// against the file's **last** decodable record.
class AgentStateFileRules {
  const AgentStateFileRules({
    this.idle = const [],
    this.working = const [],
    this.awaitingApproval = const [],
    this.failed = const [],
    this.activityWindow = const Duration(minutes: 2),
  });

  final List<StateRecordMatcher> idle;
  final List<StateRecordMatcher> working;
  final List<StateRecordMatcher> awaitingApproval;
  final List<StateRecordMatcher> failed;

  /// How recently the file must have changed for a `working` record to still
  /// mean "working" rather than "the CLI exited mid-turn".
  final Duration activityWindow;
}

/// How to install callbacks into an agent's own hook configuration, and what
/// each callback means.
class AgentHookSpec {
  const AgentHookSpec({
    required this.configFileName,
    this.configKey = 'hooks',
    this.sessionIdPath = const ['session_id'],
    this.cwdPath = const ['cwd'],
    this.messagePath = const [],
    this.messageWaiting = const {},
    required this.eventStatus,
  });

  /// Config file inside the agent's store home, e.g. `settings.json`.
  final String configFileName;

  /// Top-level key in that file holding the hook map.
  final String configKey;

  /// Where the agent's session id sits in the hook payload.
  final List<String> sessionIdPath;

  /// Where the directory the agent is working in sits in the payload, or empty
  /// when this agent's hooks carry none.
  ///
  /// Only session *adoption* reads this, and only to tell one candidate pane
  /// from another when more than one is running the same agent. A missing or
  /// unreadable value costs precision, never correctness: adoption falls back
  /// to the oldest unclaimed pane rather than refusing.
  final List<String> cwdPath;

  /// Where a human-readable description of *what the agent wants* sits in the
  /// payload, or empty when this agent's hooks carry none.
  ///
  /// The only thing that ever tells us what is being approved in words the
  /// agent itself chose. Claude Code's `Notification` payload has a `message`;
  /// it used to be decoded and thrown away, which left the whole app able to
  /// say "an approval is pending" and never what for. Empty means we quote
  /// nothing rather than inventing a description.
  final List<String> messagePath;

  /// Hook event name → the status it implies.
  final Map<String, AgentActivityStatus> eventStatus;

  /// Substring of the hook's message → what the agent is waiting on, matched
  /// case-insensitively in declaration order.
  ///
  /// An event name alone cannot answer this. Claude Code's `Notification` fires
  /// both for a permission request and for a turn that ended and is waiting on
  /// the user, and only the message tells them apart. A message matching
  /// nothing here stays [AgentWaitKind.unrecorded]: an agent that reworded its
  /// prompt costs us an Approve button, which is the direction that cannot send
  /// a keystroke into a session with no prompt open.
  final Map<String, AgentWaitKind> messageWaiting;
}

/// One answer we can send to an agent's approval prompt, and what it does.
///
/// [keys] is written to the PTY verbatim. Answering a TUI means typing into
/// another program's interface, so the button says which key it sends and
/// [effect] says what that key does *in that agent's words* — the user is
/// authorising a keystroke, not an abstraction.
class AgentApprovalKey {
  const AgentApprovalKey({
    required this.keys,
    required this.label,
    required this.effect,
  });

  /// Exactly what reaches the terminal. A control sequence (`\r`, `\x1b`), not
  /// prose, and never followed by an implicit newline.
  final String keys;

  /// The button's words.
  final String label;

  /// What this key does to this agent, shown beside the button.
  final String effect;
}

/// How an approval prompt from this agent can be answered from outside its TUI.
///
/// **Read off the agent's own screen**, which is the only place either shipped
/// agent states its keys — the same footer the [AgentGridRules] match on.
/// Declaring an answer we have not seen the agent name would be guessing at
/// another program's key bindings and pressing the result, so an undeclared
/// answer is simply unavailable and the UI points at the terminal instead.
class AgentApprovalRules {
  const AgentApprovalRules({this.approve, this.deny});

  /// The key that says yes, when the agent names one.
  final AgentApprovalKey? approve;

  /// The key that says no. Frequently absent: an agent whose prompt says only
  /// "press enter to continue" has not told us how to decline, and Esc is a
  /// guess we decline to make on the user's behalf.
  final AgentApprovalKey? deny;

  bool get isEmpty => approve == null && deny == null;
}

/// Matches one line of the terminal grid.
///
/// A plain, case-insensitive substring rather than a regular expression, on
/// purpose. The text being matched is an agent's own UI, which changes between
/// releases; a substring that stops matching produces
/// [AgentActivityStatus.unknown], which is a first-class state. A regex that
/// half-matches produces a wrong answer, which is not.
class GridMatcher {
  const GridMatcher(this.contains);

  /// Matched case-insensitively against one row of the screen.
  final String contains;

  bool matches(String line) =>
      line.toLowerCase().contains(contains.toLowerCase());

  @override
  String toString() => 'GridMatcher($contains)';
}

/// How to read an agent's status off the bottom of its own TUI — Orca's third
/// source, and the only one available to an agent with neither installed hooks
/// nor a state file we can parse.
///
/// Ordered by confidence when several match: [failed], then [awaitingApproval],
/// then [working], then [idle]. An approval prompt drawn over a spinner is
/// waiting for the user, not working.
class AgentGridRules {
  const AgentGridRules({
    this.awaitingApproval = const [],
    this.working = const [],
    this.idle = const [],
    this.failed = const [],
    this.scanLines = 12,
  });

  final List<GridMatcher> awaitingApproval;
  final List<GridMatcher> working;
  final List<GridMatcher> idle;
  final List<GridMatcher> failed;

  /// How many rows up from the bottom of the screen to consider. Small on
  /// purpose — see `terminalTailLines`.
  final int scanLines;

  bool get isEmpty =>
      awaitingApproval.isEmpty &&
      working.isEmpty &&
      idle.isEmpty &&
      failed.isEmpty;
}

/// What an agent prints when it refuses to resume a conversation another process
/// is already writing to.
///
/// Read off the screen for the same reason status is (see [AgentGridRules]):
/// an interactive CLI has no second stream to ask, so its own terminal is the
/// only place its answer exists.
///
/// [markers] are matched against the screen with **all whitespace removed from
/// both sides**, not line by line. A refusal is one long sentence — Codex's is
/// over 150 characters — so it hard-wraps at the pane width, and the wrap can
/// fall anywhere, including inside a word. Matching per line would work at some
/// terminal widths and silently stop at others.
class AgentResumeConflictRules {
  const AgentResumeConflictRules({
    this.markers = const [],
    this.scanLines = 30,
  });

  final List<GridMatcher> markers;

  /// How many rows up from the bottom to read. Larger than [AgentGridRules]'s
  /// window because this is a *post-mortem*: the agent has exited, left the
  /// alternate screen, and its last words may sit above whatever the shell
  /// printed afterwards.
  final int scanLines;

  bool get isEmpty => markers.isEmpty;
}

/// What an agent prints when it is asked to resume a conversation it has never
/// heard of.
///
/// The other half of [AgentResumeConflictRules]. Both are post-mortems read off
/// a pane that has just died, and they answer opposite questions about the same
/// dead pane: *someone else has it* versus *nobody has it, because it was never
/// written*. Claude Code's is
///
/// ```
/// No conversation found with session ID: 4b13c55e-ec74-4c0b-ac63-44747861aabd
/// ```
///
/// This is the fallback, not the fix. The store is asked before a resume is
/// attempted (`conversationPresenceProvider`), and this is what remains for the
/// case where the store could not be read — a stopped WSL distribution, an
/// unusual `CLAUDE_CONFIG_DIR` — so the attempt still explains itself instead of
/// leaving an error on a pane and a row that says "running".
///
/// Matching lives on the class rather than beside `showsResumeConflict` because
/// the rules and the reading of them are the same fact, and a second free
/// function would be a second place to forget the whitespace rule below.
class AgentMissingConversationRules {
  const AgentMissingConversationRules({
    this.markers = const [],
    this.scanLines = 30,
  });

  final List<GridMatcher> markers;

  /// How many rows up from the bottom to read. Same window as
  /// [AgentResumeConflictRules] and for the same reason: the agent has exited
  /// and its last words may sit above whatever the shell printed afterwards.
  final int scanLines;

  bool get isEmpty => markers.isEmpty;

  /// Whether [tailLines] show that answer.
  ///
  /// **Whitespace is removed from both sides before comparing**, exactly as
  /// `showsResumeConflict` does it: the line hard-wraps at the pane width and
  /// the wrap can fall inside a word, so a per-line substring match would work
  /// at some terminal widths and silently stop at others.
  ///
  /// False for an agent that declares no marker. An undeclared message means
  /// "we cannot explain this", never a guessed explanation.
  bool matchedBy(List<String> tailLines) {
    if (markers.isEmpty || tailLines.isEmpty) return false;
    final screen = _squeezed(tailLines.join(' '));
    for (final marker in markers) {
      if (screen.contains(_squeezed(marker.contains))) return true;
    }
    return false;
  }
}

/// Lower-cased with every whitespace character dropped.
String _squeezed(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'\s+'), '');
