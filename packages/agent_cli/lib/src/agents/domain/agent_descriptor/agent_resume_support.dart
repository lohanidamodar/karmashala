part of '../agent_descriptor.dart';

/// How an agent CLI expresses "continue this session".
enum AgentResumeStyle {
  /// A flag before the prompt, e.g. `--resume <id>`.
  flag,

  /// A subcommand, e.g. `codex resume <id>`.
  subcommand,

  /// The agent cannot resume from the command line.
  unsupported,
}

/// One agent's resume convention.
class AgentResume {
  const AgentResume.flag(this.token) : style = AgentResumeStyle.flag;
  const AgentResume.subcommand(this.token)
    : style = AgentResumeStyle.subcommand;
  const AgentResume.unsupported()
    : style = AgentResumeStyle.unsupported,
      token = '';

  final AgentResumeStyle style;
  final String token;

  /// Whether this agent can be told to continue a conversation at all.
  ///
  /// The question a caller has to ask **before** building a command line, and
  /// the reason it is exposed rather than left implicit in an empty argument
  /// list: an unsupported resume and a resume with nothing to resume both come
  /// back from [argumentsFor] as `[]`, and only the first of them means "do not
  /// hand this to the user as a resume command".
  bool get isSupported => style != AgentResumeStyle.unsupported;

  List<String> argumentsFor(String sessionId) =>
      style == AgentResumeStyle.unsupported ? const [] : [token, sessionId];
}

/// How an agent CLI starts a **new** conversation that already contains an
/// existing one's history.
///
/// A fork is not a resume and it is not a fan-out: the new conversation shares
/// everything said so far and then diverges, so the original is left exactly as
/// it was rather than being continued or re-prompted from scratch.
enum AgentForkStyle {
  /// The CLI does it itself, from its own copy of the transcript.
  native,

  /// The CLI cannot, but it will accept a handoff packet as an opening prompt —
  /// so the *history* is carried as text rather than as the agent's own record.
  /// A weaker thing, and the UI must say so before it happens.
  viaHandoff,

  /// Neither. Nothing is offered.
  unsupported,
}

/// Whether one agent can fork a conversation, and how.
///
/// Modelled exactly like [AgentLaunchSpec.allowsConcurrentResume] — declared
/// data on the descriptor, defaulting to the conservative answer — so "Claude
/// forks with a flag, Codex forks with a subcommand, Antigravity cannot" is
/// read from the registry rather than re-derived per call site, and an agent
/// added tomorrow is answered by the same rule.
///
/// **Defaults to [AgentForkStyle.unsupported]**, because the failure modes are
/// asymmetric in the same direction they are for concurrent resume. Not
/// offering a fork that would have worked costs a menu entry; offering one that
/// does not means handing a CLI arguments it will reject, which surfaces to the
/// user as the agent refusing to launch — twice now the exact shape of the
/// worst bug in this area (see the Codex approval flags in
/// descriptor).
class AgentForkSupport {
  /// The CLI forks by itself. [resume] is how it is told *which* conversation —
  /// a flag for Claude Code, a subcommand for Codex — and [extraArguments] is
  /// whatever else turns that reference into a fork rather than a resume.
  ///
  /// [evidence] is required and is the `--help` line or transcript this was
  /// read off, so the claim can be re-checked against a future CLI version
  /// instead of being trusted because it is written down.
  const AgentForkSupport.native({
    required this.resume,
    this.extraArguments = const [],
    required this.evidence,
  }) : style = AgentForkStyle.native;

  /// The CLI has no fork of its own, but takes an opening prompt, so a handoff
  /// packet is the honest substitute. [evidence] says what was checked.
  const AgentForkSupport.viaHandoff({required this.evidence})
    : style = AgentForkStyle.viaHandoff,
      resume = const AgentResume.unsupported(),
      extraArguments = const [];

  /// Nothing is known to work. The default.
  const AgentForkSupport.unsupported()
    : style = AgentForkStyle.unsupported,
      resume = const AgentResume.unsupported(),
      extraArguments = const [],
      evidence = '';

  final AgentForkStyle style;

  /// How the conversation being forked is named on the command line.
  final AgentResume resume;

  /// Flags that turn [resume]'s reference into a fork.
  final List<String> extraArguments;

  /// Where this was verified. Empty only for [AgentForkStyle.unsupported],
  /// where there is nothing to have verified.
  final String evidence;

  bool get isNative => style == AgentForkStyle.native;

  /// The arguments that fork [externalSessionId], or nothing when this agent
  /// cannot be told.
  ///
  /// These **replace** [AgentLaunchSpec.interactiveResume]'s arguments rather
  /// than joining them: Codex's fork is the `fork` subcommand *instead of*
  /// `resume`, and emitting both would be two subcommands on one command line.
  List<String> argumentsFor(String externalSessionId) =>
      style == AgentForkStyle.native && externalSessionId.isNotEmpty
      ? [...resume.argumentsFor(externalSessionId), ...extraArguments]
      : const [];
}

/// Whether an agent can still find a conversation when it is asked to resume it
/// from a directory other than the one it was launched in.
///
/// The question exists because this app **moves sessions between directories on
/// purpose**: archiving a worktree keeps the session row and falls back to the
/// repository root, and a native fork into a new worktree runs
/// `--resume <id> --fork-session` from a directory the source conversation was
/// never started in. If a resume were cwd-keyed, each of those would hand the
/// user a CLI that starts a *brand-new* conversation wearing the old session's
/// name — the same failure [AgentResume]'s `_ => []` arm used to cause, and the
/// one `resumeRefusalFor` exists to prevent.
///
/// cmux models the same fact as `AgentCwdNamespacing.byDirectory` vs
/// `cwdInFile` and states the consequence flatly: *"Resuming from a different
/// directory looks in the wrong namespace and fails with 'No conversation
/// found'."* **That consequence was checked against the CLIs on this machine
/// and does not hold for any of the three we ship against** — see each
/// descriptor's [evidence]. What survives the check is
/// cmux's *default*, which is kept here for the same reason it keeps it: an
/// agent whose store nobody has read is assumed to be cwd-keyed, because
/// refusing a resume that would have worked costs a click and a resume that
/// silently opens an empty conversation costs the user's work.
///
/// [evidence] is required for [AgentResumeLocality.anyDirectory] and is the
/// store layout or decompiled lookup this was read off, so a future CLI version
/// can be re-checked rather than trusted. It is the same contract
/// [AgentForkSupport], [AgentMcpSupport] and [AgentContinueSupport] hold their
/// claims to.
class AgentResumeLocality {
  /// The conversation is addressed by id and the CLI finds it wherever it is
  /// launched.
  const AgentResumeLocality.anyDirectory({required this.evidence})
    : findsConversationAnywhere = true;

  /// The conversation can only be found from the directory it was started in —
  /// or nobody has checked, which is treated the same way. The default.
  const AgentResumeLocality.launchDirectory({this.evidence = ''})
    : findsConversationAnywhere = false;

  /// True only when a resume by id has been *verified* to work from any
  /// directory.
  final bool findsConversationAnywhere;

  /// Where that was verified. Empty means "nobody looked", which is exactly
  /// what a [AgentResumeLocality.launchDirectory] default means.
  final String evidence;
}

/// Whether an agent lets us choose its session id, and how.
///
/// This is the difference between knowing a PTY-hosted session's CLI id at
/// launch and having to go looking for it afterwards. Claude Code takes
/// `--session-id <uuid>`; Codex has no equivalent and its id can only be
/// discovered from the rollout file it writes. Recording that as a capability
/// keeps the asymmetry in the registry instead of in an `if` somewhere.
class AgentSessionIdAssignment {
  const AgentSessionIdAssignment.flag(this.token) : isSupported = true;
  const AgentSessionIdAssignment.unsupported()
    : token = '',
      isSupported = false;

  final String token;
  final bool isSupported;

  /// The arguments that pin the agent's session id to [sessionId], or nothing
  /// when the agent cannot be told.
  ///
  /// [sessionId] must be a UUID; Karmashala's own session ids already are (see
  /// `RandomIdGenerator`), which is what lets one string be both.
  List<String> argumentsFor(String sessionId) =>
      isSupported ? [token, sessionId] : const [];
}

/// Whether an agent states, in its own output, the session id it chose.
///
/// The third way a session id can become known, and the one the registry was
/// missing. The other two are [AgentSessionIdAssignment] — we pick the id and
/// hand it over, which is Claude Code — and a store scan, where we go looking
/// afterwards and match on a directory and a time, which is Codex.
///
/// Antigravity needs a third because neither works for it. `agy` mints its own
/// id, so it cannot be told one; and its store names every conversation without
/// saying which of them belongs to the pane in front of us, so a scan has to
/// guess. But the CLI *does* say it — it prints its own resume command as it
/// exits — and a line the agent printed in our own pane is not a guess about
/// which conversation it was. That makes this the strongest of the three
/// signals for an agent that has it, ahead of any store heuristic.
///
/// [pattern] is a regular expression with **one capturing group** holding the
/// id. [evidence] is where the format was read, so a future CLI version can be
/// re-checked rather than trusted.
class AgentSessionIdAnnouncement {
  const AgentSessionIdAnnouncement.pattern({
    required this.pattern,
    required this.evidence,
  });

  /// This agent says nothing. The default, and the answer for an agent whose
  /// output nobody has read.
  const AgentSessionIdAnnouncement.none() : pattern = '', evidence = '';

  final String pattern;
  final String evidence;

  bool get isSupported => pattern.isNotEmpty;

  /// The id [text] announces, or `null` when it announces none.
  ///
  /// **The last match wins.** A pane holds a whole session's scrollback and can
  /// carry more than one announcement — a resume prints the id it was given,
  /// and the CLI prints it again on the way out — so the newest is the one that
  /// describes the conversation the pane is on now.
  String? idIn(String text) {
    if (!isSupported || text.isEmpty) return null;
    final matches = RegExp(pattern).allMatches(text);
    if (matches.isEmpty) return null;
    final id = matches.last.group(1);
    return id == null || id.isEmpty ? null : id;
  }
}

/// What an agent means by "the most recent conversation".
enum AgentContinueScope {
  /// The most recent conversation **in the directory the CLI is launched
  /// from**. Recency alone would be a guess about which conversation the user
  /// meant; recency within one directory is a much narrower claim, and it is
  /// only usable at all when the app can read *which* conversation that is
  /// before offering it.
  workingDirectory,
}

/// Whether an agent can be told to continue its most recent conversation
/// without being given an id, and what "most recent" is scoped to.
///
/// This is the honest fallback for an agent whose id we failed to learn, and it
/// exists because the alternative is a refusal. It is deliberately **not** the
/// same thing as Codex's `--last` picker, which Codex's descriptor declines
/// to use: that would replace an id the app already has with a recency guess.
/// This is only ever reached when there is no id at all, and — for Antigravity,
/// the one agent that declares it — the app can read exactly which conversation
/// would be continued before offering to continue it. A fallback that can name
/// its target is not a guess.
///
/// [evidence] is required, like [AgentForkSupport]'s and [AgentMcpSupport]'s,
/// and for the same reason.
class AgentContinueSupport {
  const AgentContinueSupport.flag(
    this.token, {
    required this.scope,
    required this.evidence,
  });

  /// Nothing verified. The default.
  const AgentContinueSupport.unsupported()
    : token = '',
      scope = null,
      evidence = '';

  final String token;

  /// `null` exactly when this is unsupported.
  final AgentContinueScope? scope;

  final String evidence;

  bool get isSupported => token.isNotEmpty;

  List<String> get arguments => isSupported ? [token] : const [];
}
