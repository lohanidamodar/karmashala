part of '../agent_descriptor.dart';

/// How an agent CLI is handed the first thing to say.
enum AgentPromptStyle {
  /// A trailing positional argument, e.g. `claude "do the thing"`.
  positional,

  /// A flag carrying the prompt as its value, e.g.
  /// `agy --prompt-interactive "do the thing"`.
  flag,

  /// The CLI takes no opening prompt on its command line.
  unsupported,
}

/// Whether an agent can be given an opening prompt at launch, and **how**.
///
/// Modelled like [AgentResume] and [AgentMcpSupport] rather than as the bool it
/// replaced, because *whether* and *how* turned out to be different questions
/// and the bool could only hold the first. It read "a trailing positional is
/// taken as the prompt", so an agent that takes one behind a flag had to be
/// declared as taking none at all — which is how Antigravity ended up the one
/// CLI a fan-out could not hand a task to, despite `agy` having accepted an
/// opening prompt the whole time.
///
/// Defaults to [AgentPromptStyle.unsupported], for the same reason the bool
/// defaulted to false: an agent nobody has checked is launched bare rather than
/// handed a stray argument it may read as a subcommand.
class AgentPromptSupport {
  /// The prompt is the trailing positional argument. Claude Code and Codex.
  const AgentPromptSupport.positional({this.evidence = ''})
    : style = AgentPromptStyle.positional,
      token = '';

  /// The prompt is the value of [token], emitted as **two** argv entries.
  ///
  /// Two rather than one `--flag=value` token because that is what the CLIs
  /// this models actually parse: `agy` uses Go's `flag` package, which reads
  /// the value as the next argument and exits on `flag needs an argument:
  /// -prompt-interactive` when there is none. Nothing here is variadic, so
  /// unlike Claude's `--mcp-config` the pair cannot swallow what follows it.
  const AgentPromptSupport.flag(this.token, {this.evidence = ''})
    : style = AgentPromptStyle.flag;

  /// Nothing is known to work. The default.
  const AgentPromptSupport.unsupported()
    : style = AgentPromptStyle.unsupported,
      token = '',
      evidence = '';

  final AgentPromptStyle style;

  /// The flag the prompt rides on, for [AgentPromptStyle.flag]. Empty for the
  /// other two, which name no option.
  final String token;

  /// Where this was verified — the `--help` line it was read off — so a future
  /// CLI version can be re-checked rather than trusted.
  final String evidence;

  /// Whether this agent takes an opening prompt on its command line at all.
  ///
  /// The question the refusal gates ask *before* building a command line, and
  /// separate from [argumentsFor] for [AgentResume.isSupported]'s reason: an
  /// unsupported prompt and an empty prompt both come back as `[]`, and only
  /// the first means "tell the user this message would be dropped".
  bool get isSupported => style != AgentPromptStyle.unsupported;

  /// The arguments that deliver [prompt], or nothing when it cannot be given.
  ///
  /// An empty [prompt] yields nothing whatever the style: for a flag that is
  /// not a weaker launch but a failed one, since `agy --prompt-interactive`
  /// with no value refuses to start at all.
  List<String> argumentsFor(String prompt) {
    if (prompt.isEmpty) return const [];
    return switch (style) {
      AgentPromptStyle.positional => [prompt],
      AgentPromptStyle.flag => [token, prompt],
      AgentPromptStyle.unsupported => const [],
    };
  }
}

/// How one CLI is asked for a recap of a conversation, non-interactively.
///
/// Every CLI here has a print mode; what they do **not** share is how the
/// conversation gets in. Two read it off stdin, one takes only text on the
/// command line, and that difference decides where the turns ride — so it is
/// declared per agent with the `--help` it was read off, exactly as every other
/// capability in this file is.
///
/// [prefix] is what goes before the prompt, and the prompt is always the last
/// argument: `['-p']` becomes `claude -p <prompt>`, `['exec']` becomes
/// `codex exec <prompt>`. One shape for all three, so the only thing that
/// varies is [readsTurnsFromStdin].
class AgentRecapSupport {
  /// The CLI reads the conversation from **stdin**; [prefix] plus the fixed
  /// request is the whole command line.
  const AgentRecapSupport.overStdin(this.prefix, {required this.evidence})
    : readsTurnsFromStdin = true,
      isSupported = true,
      wasChecked = true;

  /// The CLI's print mode takes the text itself and reads no conversation from
  /// anywhere, so the turns ride **inside the prompt argument**.
  ///
  /// This is the weaker of the two and is declared as such rather than papered
  /// over: an argument is a command line, and a command line has a length the
  /// operating system enforces — on Windows 32,767 characters, well under the
  /// 64 KiB a transcript is bounded to. A conversation that overruns it fails
  /// loudly at the spawn instead of arriving silently truncated, which is the
  /// right way round.
  const AgentRecapSupport.inPrompt(this.prefix, {required this.evidence})
    : readsTurnsFromStdin = false,
      isSupported = true,
      wasChecked = true;

  /// Checked, and this CLI has no non-interactive mode to ask. [evidence] is
  /// the `--help` that says so.
  const AgentRecapSupport.absent({required this.evidence})
    : prefix = const [],
      readsTurnsFromStdin = false,
      isSupported = false,
      wasChecked = true;

  /// Nobody looked. **The default**, and never reported as an absence.
  const AgentRecapSupport.unchecked()
    : prefix = const [],
      evidence = '',
      readsTurnsFromStdin = false,
      isSupported = false,
      wasChecked = false;

  /// The arguments before the prompt, e.g. `['-p']` or `['exec']`.
  final List<String> prefix;

  /// Where this was verified. Empty exactly when nobody looked.
  final String evidence;

  /// Whether the conversation is handed over on stdin rather than in the
  /// prompt argument.
  final bool readsTurnsFromStdin;

  final bool isSupported;

  /// Whether this answer was measured. False is the unchecked default, which
  /// must not be read as "this agent has none".
  final bool wasChecked;

  /// The full argument list for a recap of [turns] using [request].
  ///
  /// [modelArguments] are the descriptor's own `--model` pair, or empty when
  /// the CLI takes none — the recap is written by the model the session runs
  /// on wherever that can be asked for, so the row can name it truthfully.
  List<String> argumentsFor({
    required String request,
    required String turns,
    List<String> modelArguments = const [],
  }) => [
    ...prefix,
    ...modelArguments,
    readsTurnsFromStdin ? request : '$request\n\n$turns',
  ];

  /// What to write to the process's stdin, or null when it reads none.
  String? stdinFor(String turns) => readsTurnsFromStdin ? turns : null;
}

/// Whether an agent takes an extra system prompt as a **file**, and how.
///
/// The question a handoff turns on. A packet is large by design, and every
/// other way in is a paste: Claude Code collapses one over 800 characters or
/// three lines into `[Pasted text #N]`, so the receiving agent can read a
/// placeholder where the brief should be. A path is the same size whatever it
/// points at.
///
/// **Three values rather than two**, for §19's reason. An agent whose `--help`
/// was read and names no such option is a different fact from one nobody has
/// checked, and only the first is evidence. The launch diagnostics say which,
/// so "this packet was typed" always comes with why.
class AgentSystemPromptFileSupport {
  /// The file rides on [token], as two argv entries. [evidence] is what it was
  /// read off, so a future CLI version is re-checked rather than trusted.
  const AgentSystemPromptFileSupport.append(
    this.token, {
    required this.evidence,
  }) : isSupported = true,
       wasChecked = true;

  /// Checked, and this agent has no such option. [evidence] is the `--help`
  /// that says so.
  const AgentSystemPromptFileSupport.absent({required this.evidence})
    : token = '',
      isSupported = false,
      wasChecked = true;

  /// Nobody looked. **The default**, and never reported as an absence.
  const AgentSystemPromptFileSupport.unchecked()
    : token = '',
      evidence = '',
      isSupported = false,
      wasChecked = false;

  /// The option itself, e.g. `--append-system-prompt-file`. Empty otherwise.
  final String token;

  /// Where this was verified. Empty exactly when nobody looked.
  final String evidence;

  final bool isSupported;

  /// Whether this answer was measured. False is the unchecked default, which
  /// must not be read as "this agent has none".
  final bool wasChecked;

  /// The arguments that hand this agent the file at [path], or nothing.
  List<String> argumentsFor(String? path) =>
      isSupported && path != null && path.isNotEmpty ? [token, path] : const [];
}

/// Whether an agent can be granted a directory beyond its workspace on its
/// command line, and how.
///
/// The question a prompt written to a file turns on. An agent with no
/// system-prompt file is handed a long or multi-line opening message as a
/// file under Karmashala's data directory and told to read it; an agent that
/// asks before it reads outside its workspace then asks about Karmashala's
/// own file. Granting that one directory at launch lets it read the brief
/// without asking, and nothing is written into the person's repository.
class AgentExtraDirectorySupport {
  /// The directory rides on [token], as two argv entries, one directory per
  /// flag. [evidence] is what it was read off.
  const AgentExtraDirectorySupport.flag(this.token, {required this.evidence})
    : isSupported = true;

  /// Nobody established one. **The default**: nothing is granted.
  const AgentExtraDirectorySupport.unsupported()
    : token = '',
      evidence = '',
      isSupported = false;

  /// The option itself, e.g. `--add-dir`. Empty otherwise.
  final String token;

  /// Where this was verified. Empty exactly when nobody looked.
  final String evidence;

  final bool isSupported;

  /// The arguments that grant this agent [path], or nothing.
  List<String> argumentsFor(String? path) =>
      isSupported && path != null && path.isNotEmpty ? [token, path] : const [];
}

/// The key this agent binds to **paste the image on the clipboard**, by where
/// it runs.
///
/// A pane cannot paste an image as text, so it sends the agent this key and
/// the agent reads the clipboard itself. The key differs by platform, not by
/// shell: Claude Code binds `alt+v` on Windows and WSL because Windows
/// terminals keep `ctrl+v` for text, and adds `ctrl+v` under WSL only. So a
/// `ctrl+v` sent to Claude Code on Windows did nothing at all.
///
/// Defaults to `ctrl+v` everywhere — what every pane sent before this was
/// measured — so an agent nobody has checked behaves as it always did.
class AgentImagePasteKey {
  const AgentImagePasteKey({
    this.windowsNative = ctrlV,
    this.wsl = ctrlV,
    this.elsewhere = ctrlV,
    this.evidence = '',
  });

  static const String ctrlV = '\x16';

  /// `alt+v` as a terminal sends it: `ESC` then the letter.
  static const String altV = '\x1bv';

  final String windowsNative;
  final String wsl;

  /// A POSIX host, local or over SSH.
  final String elsewhere;

  /// Where the keys were read off. Empty for the unchecked default.
  final String evidence;

  String keyFor(EnvironmentKind kind) => switch (kind) {
    EnvironmentKind.windowsNative => windowsNative,
    EnvironmentKind.wsl => wsl,
    EnvironmentKind.localPosix || EnvironmentKind.ssh => elsewhere,
  };
}

/// The media types one agent reads from a path written into its prompt.
///
/// **Defaults to none**, and the asymmetry is the same one [AgentForkSupport]
/// argues. Not offering an attachment an agent would have read costs a button;
/// offering one it will not read means a phone spends a megabyte of somebody's
/// mobile data on a file that lands on a desktop and is never looked at — and
/// the user is told it worked.
class AgentAttachmentSupport {
  /// Nothing may be sent to this agent. [refusal] is the sentence the phone is
  /// shown in place of the button; it is the host's words because only the
  /// host has ever seen this CLI.
  const AgentAttachmentSupport.none({this.refusal = ''})
    : mediaTypes = const [],
      evidence = '';

  /// This agent reads [mediaTypes] from a path in its prompt. [evidence] is
  /// where that was read off, so a future CLI version can be re-checked rather
  /// than trusted because it is written down.
  const AgentAttachmentSupport.byPath(this.mediaTypes, {required this.evidence})
    : refusal = '';

  final List<String> mediaTypes;

  /// Empty exactly when nothing is accepted.
  final String evidence;

  /// Why nothing is accepted, when there are words for it. Empty for an agent
  /// nobody has written a sentence about, which the phone shows as nothing
  /// rather than as a guess.
  final String refusal;

  bool get isSupported => mediaTypes.isNotEmpty;
}
