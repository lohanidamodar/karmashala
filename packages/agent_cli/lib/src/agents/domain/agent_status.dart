import 'agent_tool_ask.dart';
import 'agent_working_line.dart';

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

  /// The runtime speaking the agent's protocol (ACP) said so itself. As
  /// authoritative as [hook]: the agent reported it, nobody inferred it.
  protocol,

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

  /// A multiple-choice question is open (Claude Code's AskUserQuestion).
  /// **Never answered with Approve/Deny**: the approve key is Enter, which
  /// chooses whichever option is highlighted. Answered only through the
  /// agent's [AgentQuestionSupport], with the option the user picked.
  question,
}

/// **What a CLI said about its own session ending**, when it said anything.
///
/// The whole point is what is *not* here. A pane's exit code is not one of
/// these: exit 0 covers a Ctrl-C, a wrapper that fell over before the agent
/// started and a clean finish alike, so turning it into a word would put an
/// ending on all three. Only an event the agent itself fires — Claude Code's
/// `SessionEnd` and `StopFailure`, Codex's `SessionEnd`, Antigravity's `Stop`
/// with a failing `terminationReason` — reaches this type at all.
///
/// No `cancelled`: no CLI here distinguishes a run the user
/// stopped from one that ended by itself in a hook, and the user's own stop is
/// already written by whoever performed it.
enum AgentSessionEnding {
  /// The agent's own run ended, and nothing said it ended badly.
  completed,

  /// The CLI named a failure — an API error, an exhausted budget.
  failed,

  /// Only the **conversation** ended — Claude Code's `/clear` or `/resume` —
  /// and the CLI carries on in the same pane with another. Still an ending to
  /// whoever tracks conversations; never an ending of the session row.
  conversationOnly,
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
    this.ending,
    this.failureReason,
    this.toolAsk,
    this.waitingSince,
    this.inFlight = const [],
    this.backgroundOnly = false,
    this.working,
  });

  /// This report with the ask it is about and when the wait began — both
  /// cleared when null. Everything else stays as it was read.
  AgentStatusReport withAsk({AgentToolAsk? toolAsk, DateTime? waitingSince}) =>
      _copy(toolAsk: toolAsk, waitingSince: waitingSince, working: working);

  /// This report with [working] in place of its own, cleared when null.
  AgentStatusReport withWorking(AgentWorkingDetail? working) =>
      _copy(toolAsk: toolAsk, waitingSince: waitingSince, working: working);

  AgentStatusReport _copy({
    required AgentToolAsk? toolAsk,
    required DateTime? waitingSince,
    required AgentWorkingDetail? working,
  }) => AgentStatusReport(
    agentId: agentId,
    sessionId: sessionId,
    status: status,
    observedAt: observedAt,
    source: source,
    detail: detail,
    sourceModifiedAt: sourceModifiedAt,
    evidence: evidence,
    waiting: waiting,
    ending: ending,
    failureReason: failureReason,
    toolAsk: toolAsk,
    waitingSince: waitingSince,
    inFlight: inFlight,
    backgroundOnly: backgroundOnly,
    working: working,
  );

  /// **What the agent's working line says** while its turn runs — its word,
  /// when the turn began and its tokens — and once the turn has ended, the
  /// past-tense word it left ("Crunched"). Null when no source said any of it.
  final AgentWorkingDetail? working;

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

  /// **What the agent said about its session ending**, or null — which is the
  /// normal answer, because most events are about a turn.
  ///
  /// Only a hook carries one. A transcript read and a terminal screen describe
  /// what a session is *doing*, and neither can witness it stopping; see
  /// `SessionOutcomeWriter`, the one consumer.
  final AgentSessionEnding? ending;

  /// The agent's own word for why a turn failed — Claude Code's `rate_limit`,
  /// `server_error` — or null when it gave none. Opaque: compared, never shown.
  final String? failureReason;

  /// **The tool call an open prompt asks about**, read off the hook that
  /// announced it — only while [hasOpenPrompt], and only for an agent whose
  /// hooks carry the call. Null is the normal case: the screen is then the
  /// only account of what is asked.
  final AgentToolAsk? toolAsk;

  /// When the session began waiting on the user, while it is — so "waiting
  /// 42s" counts from the ask, not from whoever looked last. Null when it is
  /// not waiting, or the source could not tell.
  final DateTime? waitingSince;

  /// **Work still running after the turn handed off** — a background subagent
  /// or shell — named in the agent's own words. Non-empty only while the agent
  /// said so; a session holding any is working, however long it stays quiet.
  final List<String> inFlight;

  /// **Whether the agent's own turn has ended** and [status] reads working
  /// only for the work in [inFlight]: the agent is at its prompt and takes
  /// input. Background runs are not a turn.
  final bool backgroundOnly;

  /// [status] as far as the agent's own turn goes: idle while it reads
  /// working only for its background work.
  AgentActivityStatus get turnStatus =>
      backgroundOnly ? AgentActivityStatus.idle : status;

  /// **Whether a prompt with options is on this session's screen right now.**
  ///
  /// The one rule every surface that puts a keystroke into a pane turns on, in
  /// one place so they cannot disagree: the approval card draws its buttons
  /// from it, the phone offers approve/deny from it, and `session_send` refuses
  /// to type from it.
  ///
  /// Both halves are needed. [AgentActivityStatus.awaitingApproval] alone says
  /// the session stopped for the user, which is equally true of an agent
  /// sitting at its own input — and at an idle prompt a carriage return submits
  /// whatever is in the composer. Only a source with positive evidence of a
  /// prompt claims [AgentWaitKind.approval], so anything less is *not* an open
  /// prompt, [AgentWaitKind.unrecorded] included.
  bool get hasOpenPrompt =>
      status == AgentActivityStatus.awaitingApproval &&
      waiting == AgentWaitKind.approval;

  /// **Whether a multiple-choice question is on this session's screen.** Not an
  /// open prompt — nothing may answer it with Approve/Deny — but just as much a
  /// modal a typed message would land in.
  bool get hasOpenQuestion =>
      status == AgentActivityStatus.awaitingApproval &&
      waiting == AgentWaitKind.question;

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
/// comparing the value there to [equals].
///
/// [equals] is `Object` rather than `String` because the field that means "this
/// turn ended in an error" is not always a string. Claude Code marks a failed
/// turn with the **boolean** `isApiErrorMessage: true` and nothing else
/// distinguishes it from a finished one — same `type`, same content shape — so
/// while this compared string values only, the record that says a session broke
/// matched the idle rule and the app announced it as finished.
class StateRecordMatcher {
  const StateRecordMatcher(this.path, this.equals) : elementField = null;

  /// Matches when the **list** at [path] holds an object whose [elementField]
  /// equals [equals].
  ///
  /// A record's `type` is not always enough to classify it. A Claude Code
  /// transcript writes a tool call as an *assistant* record whose
  /// `message.content` holds a `tool_use` block, and the matching `tool_result`
  /// only arrives in a later user record — so the record that means "a turn is
  /// in flight" and the record that means "the turn ended" have the same
  /// `type`, and only the blocks inside tell them apart. Without this the
  /// classifier reported a session waiting on a ten-minute subagent as
  /// finished.
  const StateRecordMatcher.anyIn(
    this.path,
    String this.elementField,
    this.equals,
  );

  final List<String> path;

  /// The value the field must hold. Compared with `==`, so a `String` matcher
  /// still only ever matches a string.
  final Object equals;

  /// The field to compare inside each element of the list at [path], or `null`
  /// for the plain form that compares the value at [path] itself.
  final String? elementField;

  bool matches(Map<String, Object?> record) {
    Object? value = record;
    for (final segment in path) {
      if (value is! Map) return false;
      value = value[segment];
    }
    final field = elementField;
    if (field == null) return value == equals;
    if (value is! List) return false;
    for (final element in value) {
      if (element is Map && element[field] == equals) return true;
    }
    return false;
  }

  @override
  String toString() => elementField == null
      ? '${path.join('.')}=$equals'
      : '${path.join('.')}[].$elementField=$equals';
}

/// How to classify an agent's state file. All matcher lists are evaluated
/// against the file's **last** decodable record, or — for an agent that sets
/// [looksPastUnclassifiedRecords] — the last one that matches anything.
class AgentStateFileRules {
  const AgentStateFileRules({
    this.idle = const [],
    this.working = const [],
    this.awaitingApproval = const [],
    this.failed = const [],
    this.activityWindow = const Duration(minutes: 2),
    this.looksPastUnclassifiedRecords = false,
    this.failureOutlastsUnclassifiedRecords = false,
  });

  final List<StateRecordMatcher> idle;
  final List<StateRecordMatcher> working;
  final List<StateRecordMatcher> awaitingApproval;
  final List<StateRecordMatcher> failed;

  /// How recently the file must have changed for a `working` record to still
  /// mean "working" rather than "the CLI exited mid-turn".
  final Duration activityWindow;

  /// Whether a last record that matches nothing may be walked past, back to the
  /// most recent record that does.
  ///
  /// **Off by default, and it should stay off for most agents.** The last
  /// record is the strongest evidence a transcript has, and stepping back from
  /// it trades that for a guess about which older record still describes the
  /// session.
  ///
  /// Codex turns it on because its rollout interleaves bookkeeping that says
  /// nothing about activity — `token_count` is the single most frequent record
  /// in the owner's store, 9,650 of roughly 46,000, and lands *between* the
  /// records that do classify, so a live session flapped to `unknown` every
  /// time a rate-limit record arrived last. Claude Code deliberately does not:
  /// walking back would reclassify 52 of the owner's 559 transcripts from
  /// `unknown` to `idle`, and `idle` is what fires a completion notification.
  ///
  /// A record that *matches* and is merely stale — a `working` record nothing
  /// has written to since — ends the walk. Aging out is an answer, not a miss.
  final bool looksPastUnclassifiedRecords;

  /// Whether the same walk is taken for a `failed` record alone: the nearest
  /// record that matches anything is the answer only when it is a failure.
  /// Claude writes `system` bookkeeping after a turn an API error ended, which
  /// left that turn `unknown` and its quiet screen read as finished.
  final bool failureOutlastsUnclassifiedRecords;
}

/// How one agent writes a hook handler for an event.
///
/// Two shipped CLIs, two shapes, and the difference is not decorative — a flat
/// handler where a grouped one is expected is a hook that never fires.
enum AgentHookEntryStyle {
  /// `{"hooks": [{"type": "command", "command": …}]}` — Claude Code, which
  /// wraps handlers in a group so a `matcher` can select tools.
  grouped,

  /// `{"type": "command", "command": …}` — the handler object itself.
  ///
  /// Antigravity's `PreInvocation`, `PostInvocation` and `Stop` take a flat
  /// list: those events have nothing to match on, and its own documentation
  /// calls the wrapper "Grouped" for the tool events only.
  flat,
}

/// What one of an agent's own event subtypes means, when its payload carries
/// one.
///
/// Two facts rather than one because they answer different questions and the
/// wrong pairing is what shipped: [status] decides whether the session is shown
/// as holding the user up, [waiting] decides whether a key may be sent on the
/// user's behalf.
class AgentHookMeaning {
  const AgentHookMeaning(
    this.status, {
    this.waiting = AgentWaitKind.unrecorded,
    this.fallbackMessage,
    this.ending,
  });

  final AgentActivityStatus status;
  final AgentWaitKind waiting;

  /// What this subtype says about the **session**, when it says anything.
  ///
  /// Separate from [status] because they are different lifespans: `failed` as a
  /// status is what the agent is doing this second, and it ages out; an ending
  /// is written onto the row and outlives the app. Null — the default — means
  /// this subtype ends a turn and says nothing about the session, which is the
  /// answer for every subtype but Antigravity's failing ones.
  final AgentSessionEnding? ending;

  /// An explanatory message when the hook payload carries no description of its own.
  final String? fallbackMessage;

  @override
  String toString() => 'AgentHookMeaning(${status.name}, ${waiting.name})';
}

/// How to install callbacks into an agent's own hook configuration, and what
/// each callback means.
class AgentHookSpec {
  const AgentHookSpec({
    required this.configFileName,
    this.configKey = 'hooks',
    this.entryStyle = AgentHookEntryStyle.grouped,
    this.sessionIdPath = const ['session_id'],
    this.subagentIdPath = const [],
    this.cwdPath = const ['cwd'],
    this.promptPath = const ['prompt'],
    this.toolInputPath = const ['tool_input'],
    this.messagePaths = const [],
    this.messageMeaning = const {},
    this.eventKindPath = const [],
    this.eventKindMeaning = const {},
    this.inFlightPath = const {},
    this.inFlightLabelPaths = const [],
    this.eventEnding = const {},
    this.failureReasonPath = const [],
    this.endingReasonPath = const [],
    this.conversationOnlyEndReasons = const {},
    this.trustsCommandByHash = false,
    required this.eventStatus,
  });

  /// The config file, relative to the agent's store home — `settings.json`, or
  /// a path that walks out of it.
  ///
  /// Relative rather than a bare name because an agent's hook file need not
  /// live in its store. Antigravity keeps its data in
  /// `~/.gemini/antigravity-cli` and reads its customizations from
  /// `~/.gemini/config`, so its spec names `../config/hooks.json`; a file
  /// written inside the store home would be a file the CLI never opens, which
  /// is indistinguishable from not installing at all.
  final String configFileName;

  /// Top-level key in that file holding the event map.
  ///
  /// For Claude Code that is the file's `hooks` section. For Antigravity the
  /// file's top level *is* a map of hook **names**, so the key is our own name
  /// — which puts every other tool's hooks in sibling keys the byte-splice
  /// never touches.
  final String configKey;

  /// The shape of one installed handler in this agent's config.
  final AgentHookEntryStyle entryStyle;

  /// Where the agent's session id sits in the hook payload.
  final List<String> sessionIdPath;

  /// Where a subagent's own id sits, on the events it fires under its
  /// parent's session id; empty when this agent's hooks carry none.
  final List<String> subagentIdPath;

  /// Where the directory the agent is working in sits in the payload, or empty
  /// when this agent's hooks carry none.
  ///
  /// Only session *adoption* reads this, and only to tell one candidate pane
  /// from another when more than one is running the same agent. A missing or
  /// unreadable value costs precision, never correctness: adoption falls back
  /// to the oldest unclaimed pane rather than refusing.
  final List<String> cwdPath;

  /// Where the text the user submitted sits in a prompt event's payload —
  /// Claude Code and Codex both send `prompt` on `UserPromptSubmit`. Only a
  /// checkpoint's label reads it; empty or absent means none is shown.
  final List<String> promptPath;

  /// Where a tool event's arguments sit, so the paths a tool touched can name
  /// the repositories a turn changed. Empty when this agent's hooks carry none.
  final List<String> toolInputPath;

  /// Where a human-readable description of *what the agent is doing or wants*
  /// sits in the payload — **candidate paths, tried in order**, the first
  /// holding a non-empty string winning. Empty when this agent's hooks carry
  /// none.
  ///
  /// The only thing that ever tells us what is being approved, or what was
  /// finished, in words the agent itself chose. Empty means we quote nothing
  /// rather than inventing a description.
  ///
  /// A list rather than one path because the field is per **event**, not per
  /// agent, and no single key covers a CLI's whole hook surface. Claude Code
  /// 2.1.260 puts the prose under `message` on `Notification` and under
  /// `last_assistant_message` on `Stop`, `StopFailure` and `SubagentStop` — so
  /// reading only the first left every "Agent finished" toast with a session
  /// name and nothing else, which is the half of the question the user actually
  /// asked. No event carries both, so order is a fallback rather than a
  /// precedence anyone has to reason about.
  final List<List<String>> messagePaths;

  /// Hook event name → the status it implies.
  final Map<String, AgentActivityStatus> eventStatus;

  /// Substring of the hook's message → what that event actually means, matched
  /// case-insensitively in declaration order — the prose fallback for an event
  /// whose payload carries no subtype at [eventKindPath].
  ///
  /// Consulted only for an event [eventStatus] says stopped for the user
  /// ([AgentActivityStatus.awaitingApproval]): an event name alone cannot tell
  /// a permission request from a turn that ended and is sitting at its own
  /// input — Claude Code's `Notification` fires for both — and only the
  /// message tells them apart. An idle nudge is **not** a prompt: it resolves
  /// to [AgentActivityStatus.idle] here, so it never reaches an inbox as
  /// "needs you". A message matching nothing stays `awaitingApproval` with
  /// [AgentWaitKind.unrecorded]: an agent that reworded its prompt costs us an
  /// Approve button, which is the direction that cannot send a keystroke into
  /// a session with no prompt open.
  final Map<String, AgentHookMeaning> messageMeaning;

  /// Where the agent's **own** subtype for an event sits in the payload, or
  /// empty when its hooks carry none.
  ///
  /// An event name is not always a status. Claude Code fires one `Notification`
  /// for ten unrelated things — a permission request, a finished turn, a
  /// successful login, an MCP elicitation result, "Claude is done using your
  /// computer" — and its payload says which in `notification_type`. Matching
  /// prose in [messageMeaning] was a guess at that field; this is the field.
  final List<String> eventKindPath;

  /// Subtype at [eventKindPath] → what that event actually means.
  ///
  /// Consulted **before** [eventStatus], and only when the payload carries the
  /// field at all: an event whose payload has no subtype (every event but
  /// `Notification`, and any older CLI that predates the field) still falls
  /// back to [eventStatus].
  ///
  /// A subtype that *is* present and is not declared here resolves to
  /// [AgentActivityStatus.unknown], which is not recorded and so leaves the
  /// session saying whatever it last said. That is the deliberate direction: an
  /// unrecognised notice must not be able to raise "this session needs you",
  /// because that badge is what puts a key-sending button in front of a user.
  final Map<String, AgentHookMeaning> eventKindMeaning;

  /// Event name → where that event's payload lists work that is **still in
  /// flight**, for an agent whose "the turn ended" event also fires when the
  /// turn is merely *paused*.
  ///
  /// A non-empty list at that path replaces the event's [eventStatus] with
  /// [AgentActivityStatus.working]: the session did not stop, it handed off and
  /// will be woken again. Anything else — the key absent, an empty list, a
  /// value that is not a list — leaves the event meaning exactly what it says,
  /// so an agent that never sends the field is untouched.
  ///
  /// Claude Code needs this and says so in the field's own documentation.
  /// `Stop` fires on the **main thread** the moment a `Task` subagent is
  /// launched, and the payload carries `background_tasks` for precisely this
  /// question — 2.1.260's schema describes it as *"In-flight background work
  /// (running/pending + backgrounded) registered in this session. Lets hooks
  /// distinguish 'session is done' from 'session is paused waiting for
  /// background work to wake it'."*
  final Map<String, List<String>> inFlightPath;

  /// Where one [inFlightPath] entry names itself — candidate paths, first
  /// non-empty string winning — so a row can say what is still running.
  final List<List<String>> inFlightLabelPaths;

  /// Hook event name → what that event says about the **session's** ending.
  ///
  /// Read only when the payload carries no subtype at [eventKindPath]; a
  /// subtype that is present is answered by [AgentHookMeaning.ending] instead,
  /// exactly as [eventStatus] and [eventKindMeaning] divide [eventStatus]'s
  /// question.
  ///
  /// Deliberately tiny, and an event missing from it writes nothing rather
  /// than a default: `Stop` is a **turn** ending on every CLI here, and a row
  /// that said `completed` after each turn would be wrong for the whole of
  /// every session but the last turn of it.
  final Map<String, AgentSessionEnding> eventEnding;

  /// Where a failing event's payload names its cause. Empty: it names none.
  final List<String> failureReasonPath;

  /// Where an [eventEnding] event's payload names why it fired. Empty: it
  /// names nothing, and every such ending stands as declared.
  final List<String> endingReasonPath;

  /// The reasons at [endingReasonPath] that end only the conversation while
  /// the CLI stays running in its pane; they turn an ending into
  /// [AgentSessionEnding.conversationOnly]. An absent or unlisted reason keeps
  /// the declared ending, so an older CLI still finishes its row.
  final Set<String> conversationOnlyEndReasons;

  /// Whether this agent gates each hook entry on a hash of the entry itself, so
  /// the installed **command string must not change between launches**.
  ///
  /// Codex does. Every discovered handler is hashed and compared to a
  /// `trusted_hash` the user granted, and an entry that does not match is
  /// listed but never dispatched
  /// (`codex-rs/hooks/src/engine/discovery.rs`, `hook_trust_status` and the
  /// `if enabled && (bypass || Managed | Trusted)` guard around
  /// `handlers.push`).
  ///
  /// **What is hashed is the config entry, not the file the command names.**
  /// `hook_hash` builds a `NormalizedHookIdentity { event_name, matcher, hooks:
  /// [normalized handler] }`, converts it to TOML and takes
  /// `version_for_toml` — sha256 over canonical, key-sorted JSON
  /// (`codex-rs/config/src/fingerprint.rs`). Its own doc comment says why:
  ///
  ///   /// Hash a normalized, config-derived identity instead of source text so
  ///   /// equivalent hooks from config TOML and hooks.json converge on the same
  ///   /// trust identity.
  ///
  /// That single fact is what makes this installable at all. Karmashala's
  /// callback address is an **ephemeral port and a per-launch bearer token**, so
  /// a command spelling them inline would hash differently on every start and
  /// demand a fresh trust review each time — unusable. A command that names a
  /// fixed script instead hashes the same for ever, and the port and token live
  /// in the script's contents, which nothing hashes. `AgentHookInstaller` writes
  /// that script; see `hookCommand`.
  ///
  /// Two limits worth knowing before relying on it. The trust *state* is keyed
  /// on the config file's absolute path, the event, the group index and the
  /// handler index (`codex-rs/hooks/src/lib.rs`, `hook_key`), so our entry
  /// keeps its trust only while its position in that event's list is stable —
  /// adding ours last and removing only ours is what preserves it. And the
  /// grant itself is the user's: the first launch after this is installed
  /// leaves the entry
  /// untrusted, firing nothing, until they say otherwise in the CLI's own
  /// review. That is the honest shape for a callback into somebody's agent, and
  /// it is why no bypass flag is passed anywhere in this feature.
  final bool trustsCommandByHash;
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

/// **How an agent's TUI measures text and takes typed input** — the two
/// places a terminal drawing or typing for it must do what the agent does, not
/// what a shell does. Both default to a shell's behaviour, which is right for
/// an agent nobody has measured.
class AgentTerminalRules {
  const AgentTerminalRules({
    this.clusterWidthFromBase = false,
    this.pasteBurstFoldsReturn = false,
    this.typedTextArrivesWhole = false,
    this.typedOpeningLeadIn,
    this.takesInputMidTurn = false,
    this.pastePlaceholder,
    this.evidence,
  });

  /// How the composer begins the placeholder it shows **instead of** a long
  /// paste (`[Pasted text #`), matched as a plain substring: seeing it is
  /// seeing the paste land. Null when none is known.
  final String? pastePlaceholder;

  /// Whether a message typed and sent while the agent's turn runs is taken
  /// by the agent itself — queued by its composer or read at its next step —
  /// so a person's message need not wait for the turn's end.
  final bool takesInputMidTurn;

  /// Words typed, on their own, before an opening message typed in: an agent
  /// that takes the opening for a paste reads a message that is only pasted
  /// text as content rather than as the person's request. Null types none.
  final String? typedOpeningLeadIn;

  /// Whether the agent lays a grapheme cluster out at its **first code
  /// point's** width (`string-width`), so an Indic cluster (का, क्ष) takes one
  /// cell where a terminal's default gives it two. A pane hosting it must
  /// measure the same way, or the agent's redraws land in the wrong columns.
  final bool clusterWidthFromBase;

  /// Whether text typed fast is taken as a **paste burst** that folds the
  /// Return after it into a newline, so typing a message must end the burst
  /// (`Ctrl+E`) before the Return that sends it.
  final bool pasteBurstFoldsReturn;

  /// Whether a long or multi-line message typed into the composer reaches the
  /// model **whole**, though the composer may show it as a placeholder
  /// (`[Pasted text #N]`) — so an opening message can be typed in rather
  /// than written to a file.
  final bool typedTextArrivesWhole;

  /// Where the rules were read.
  final String? evidence;
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
    this.question = const [],
    this.awaitingApproval = const [],
    this.working = const [],
    this.idle = const [],
    this.failed = const [],
    this.workingLine,
    this.scanLines = 12,
  });

  /// How to read the agent's own word, elapsed time and tokens off its working
  /// line while a turn runs; null for an agent whose line nobody has read.
  final WorkingLineRule? workingLine;

  /// A multiple-choice question's footer. Checked before [awaitingApproval]:
  /// the question's footer also ends Esc to cancel, and read as an approval it
  /// would offer Approve — Enter, which answers with the highlighted option.
  final List<GridMatcher> question;

  final List<GridMatcher> awaitingApproval;
  final List<GridMatcher> working;
  final List<GridMatcher> idle;
  final List<GridMatcher> failed;

  /// How many rows up from the bottom of the screen to consider. Small on
  /// purpose — see `terminalTailLines`.
  final int scanLines;

  bool get isEmpty =>
      question.isEmpty &&
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

/// What an agent draws when it will not start work in a directory until a
/// person answers a first-run question about it — Claude Code's "Is this a
/// project you created or one you trust?", Codex's "Do you trust the contents
/// of this directory?".
///
/// Read off the **live** screen, unlike the post-mortems beside it: the agent
/// is running and waiting. A session somebody watches answers it (the approval
/// and menu keys already cover it); an unattended launch has nobody to, so the
/// daemon reads this to stop waiting and say why, never to answer it. Trusting
/// a directory is the person's decision, and it is not made on their behalf.
///
/// Markers are matched with whitespace removed from both sides, as the
/// post-mortems are: the question is prose that wraps at the pane width.
class AgentFirstRunPromptRules {
  const AgentFirstRunPromptRules({
    this.markers = const [],
    this.scanLines = 40,
  });

  /// Any one of them on screen is the question. Each is the agent's own words,
  /// read off a captured screen.
  final List<GridMatcher> markers;

  /// How many rows up from the bottom to read: the whole modal, which is taller
  /// than a footer.
  final int scanLines;

  bool get isEmpty => markers.isEmpty;

  /// Whether [tailLines] show the question. False for an agent that declares
  /// no marker: an undeclared prompt is one nobody has seen, not a guess.
  bool matchedBy(List<String> tailLines) {
    if (markers.isEmpty || tailLines.isEmpty) return false;
    final lines = tailLines.length > scanLines
        ? tailLines.sublist(tailLines.length - scanLines)
        : tailLines;
    final screen = _squeezed(lines.join(' '));
    for (final marker in markers) {
      if (screen.contains(_squeezed(marker.contains))) return true;
    }
    return false;
  }
}

/// One flag value an installed CLI refused, and what it offered instead.
///
/// Read off the agent's own refusal, so every field is the CLI's own word for
/// itself — no part of this is Karmashala's opinion about what the agent
/// should have.
class RejectedValue {
  const RejectedValue({
    required this.value,
    required this.flag,
    required this.alternatives,
  });

  /// The value that was refused — `untrusted`.
  final String value;

  /// The flag it was given to — `--ask-for-approval`.
  final String flag;

  /// The set the CLI named instead, in its own order. Never empty: a refusal
  /// that named nothing is not matched at all, because "this build does not
  /// have it and here is nothing" is no more useful than the raw stderr.
  final List<String> alternatives;

  /// `on-request, never` — for a sentence, not for a command line.
  String get alternativesLabel => alternatives.join(', ');
}

/// What an agent prints when it is handed a flag value **this installation**
/// does not have.
///
/// The third post-mortem read off a dead pane, beside [AgentResumeConflictRules]
/// and [AgentMissingConversationRules], and the only one whose cause is on our
/// side of the line: the other two are facts about the user's conversations,
/// this one is the registry being wrong about the binary in front of it.
///
/// **Mode support is a property of the installation, not of the agent.** The
/// two Codex builds on the machine this was written on disagreed —  0.145.0
/// had `untrusted`, 0.151.0 dropped it — and only the newest set is declared,
/// on the argument that the newest is a subset of the older. That argument is
/// right until it is not, and this is what happens on the day it is not: the
/// CLI refuses at parse time, exits before drawing anything, and the user is
/// left with a pane that flashed and died. The refusal itself is generous — it
/// names the whole valid set — so the only thing missing was somebody reading
/// it.
///
/// [pattern] is a regular expression with **three capturing groups, in order**:
/// the refused value, the flag, and the comma-separated set the CLI named
/// instead. It is matched case-insensitively against the screen with **all
/// whitespace removed**, exactly as the other two post-mortems are matched and
/// for the same reason: the refusal is two lines that hard-wrap at whatever
/// width the pane happens to be, and the wrap can land inside a word.
///
/// Empty for an agent whose refusal nobody has seen, which resolves to "we
/// cannot explain this" rather than to a guess.
class AgentRejectedValueRules {
  const AgentRejectedValueRules.pattern({
    required this.pattern,
    required this.evidence,
    this.scanLines = 30,
  });

  /// Nobody has seen this agent refuse a value. The default.
  const AgentRejectedValueRules.none()
    : pattern = '',
      evidence = '',
      scanLines = 30;

  final String pattern;

  /// The command and the output it was read off, so a future CLI version can be
  /// re-checked rather than trusted.
  final String evidence;

  /// How many rows up from the bottom to read. The same window as the other two
  /// post-mortems, and for the same reason: the agent has exited and its last
  /// words may sit above whatever the shell printed afterwards.
  final int scanLines;

  bool get isEmpty => pattern.isEmpty;

  /// The refusal [tailLines] show, or null when they show none.
  ///
  /// **The last match wins**, like `AgentSessionIdAnnouncement.idIn`: a pane
  /// can hold more than one dead launch, and the newest is the one that
  /// describes the attempt the user just made.
  RejectedValue? matchedBy(List<String> tailLines) {
    if (isEmpty || tailLines.isEmpty) return null;
    // Case is preserved here, unlike [_squeezed]: these captures are quoted
    // back to the user as the CLI's own words, and a lower-cased flag would be
    // a command line that does not exist.
    final screen = tailLines.join(' ').replaceAll(RegExp(r'\s+'), '');
    final matches = RegExp(pattern, caseSensitive: false).allMatches(screen);
    if (matches.isEmpty) return null;
    final match = matches.last;
    final value = match.group(1) ?? '';
    final flag = match.group(2) ?? '';
    final alternatives = [
      for (final one in (match.group(3) ?? '').split(','))
        if (one.trim().isNotEmpty) one.trim(),
    ];
    if (value.isEmpty || flag.isEmpty || alternatives.isEmpty) return null;
    return RejectedValue(value: value, flag: flag, alternatives: alternatives);
  }
}

/// Lower-cased with every whitespace character dropped.
String _squeezed(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'\s+'), '');
