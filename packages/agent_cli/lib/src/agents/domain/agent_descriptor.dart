import '../../environments/environment_kind.dart';
import '../../permissions/permission_risk.dart';
import './agent_kind.dart';
import './agent_mcp_config.dart';
import './agent_plan.dart';
import './agent_question.dart';
import './agent_permission_support.dart';
import './agent_skill_support.dart';
import './agent_status.dart';

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
/// `built_in_agents.dart`).
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

/// How an agent CLI is told, at launch, where Karmashala's own tools are.
enum AgentMcpStyle {
  /// A flag naming a config file the agent reads — Claude Code's
  /// `--mcp-config`.
  configFile,

  /// A flag setting one config value inline, with no file — Codex's
  /// `-c <dotted.key>=<value>`.
  inlineUrl,

  /// No convention we have verified. Nothing is passed. **The default.**
  unsupported,
}

/// Whether one agent can be pointed at an MCP server on its command line, and
/// how.
///
/// Modelled exactly like [AgentForkSupport] — declared data on the descriptor,
/// [evidence] required, defaulting to the conservative answer — and for the
/// same reason. Antigravity's descriptor was wrong for months because a flag
/// nobody had run was written down as if it were known; `agy --help` (1.1.22)
/// names an `mcp` *subcommand* for editing its own config and no launch option
/// at all, so Antigravity is given nothing here rather than something plausible.
///
/// Note what this is not: it is not "does the agent support MCP". All three
/// support it. It is "can this launch, without touching the user's own files,
/// add one more server for one session" — and that is a narrower question with
/// a different answer per CLI.
class AgentMcpSupport {
  /// The agent reads a config file named by [flag].
  ///
  /// Emitted as a **single `--flag=value` token**, not as two arguments, and
  /// that is load-bearing rather than cosmetic. Claude Code declares
  /// `--mcp-config <configs...>` — variadic, "space-separated" — so a
  /// space-separated value swallows every following non-flag argument,
  /// including the opening prompt this launcher passes as a positional:
  ///
  ///   $ claude --mcp-config /tmp/c.json mcp list
  ///   Error: Invalid MCP configuration:
  ///   MCP config file not found: …/mcp
  ///   MCP config file not found: …/list
  ///   $ claude --mcp-config=/tmp/c.json mcp list
  ///   claude.ai Google Drive: … ✔ Connected      # ran the subcommand
  ///
  /// Verified against 2.1.251.
  const AgentMcpSupport.configFile({required this.flag, required this.evidence})
    : style = AgentMcpStyle.configFile,
      urlKey = '';

  /// The agent takes the URL on its command line, as `[flag] <urlKey>=<url>`.
  ///
  /// No file is written, so nothing has to be readable from the agent's
  /// filesystem — which is why this is the shape Codex gets even though it also
  /// has a config file: `~/.codex/config.toml` is the *user's*, holds one
  /// `[mcp_servers.karmashala]` block for the whole machine, and so could
  /// never carry a **per-session** URL. Identity is the point of the URL, so a
  /// convention that cannot be per-session is not a weaker version of this one,
  /// it is a different and wrong thing.
  const AgentMcpSupport.inlineUrl({
    required this.flag,
    required this.urlKey,
    required this.evidence,
  }) : style = AgentMcpStyle.inlineUrl;

  /// Nothing is known to work. The default.
  const AgentMcpSupport.unsupported()
    : style = AgentMcpStyle.unsupported,
      flag = '',
      urlKey = '',
      evidence = '';

  final AgentMcpStyle style;

  /// The option itself, e.g. `--mcp-config` or `-c`.
  final String flag;

  /// For [AgentMcpStyle.inlineUrl], the dotted config key the URL is assigned
  /// to. Empty otherwise.
  final String urlKey;

  /// Where this was verified — the `--help` line or the transcript it was read
  /// off, so a future CLI version can be re-checked rather than trusted.
  final String evidence;

  bool get isSupported => style != AgentMcpStyle.unsupported;

  /// Whether a config file has to exist before [argumentsFor] can say anything.
  bool get needsConfigFile => style == AgentMcpStyle.configFile;

  /// The arguments that point this agent at [url], or nothing when it cannot be
  /// told.
  ///
  /// A [AgentMcpStyle.configFile] agent with no [configPath] gets **nothing**,
  /// not a flag with an empty value: the file could not be written, and a flag
  /// naming a file that is not there is a launch that fails where the launch
  /// without it would have succeeded.
  ///
  /// [url] is nullable for the same reason, one environment further along. A
  /// config-file agent inside a WSL distribution is pointed at a *file* that
  /// spawns the stdio bridge, because no address this app binds is reachable
  /// from there — so there is no URL to hand it, and that is a working launch
  /// rather than a missing value. An [AgentMcpStyle.inlineUrl] agent has
  /// nothing but the URL and gets nothing without one.
  List<String> argumentsFor({String? url, String? configPath}) =>
      switch (style) {
        AgentMcpStyle.configFile =>
          configPath == null ? const [] : ['$flag=$configPath'],
        AgentMcpStyle.inlineUrl => url == null || url.isEmpty
            ? const []
            : [flag, '$urlKey=$url'],
        AgentMcpStyle.unsupported => const [],
      };

  /// [arguments] with anything [argumentsFor] wrote taken back out.
  ///
  /// For reading back a launch recorded before these flags were understood to
  /// be volatile, when they were stored alongside the durable ones. Every value
  /// in such a flag is dead by the next start — the config file is deleted by
  /// `SessionMcpConfigs.prepare`, the port is rebound, the credential is
  /// re-minted — and replaying one does not weaken the launch, it fails it:
  ///
  ///   Error: Invalid MCP configuration:
  ///   MCP config file not found: `…/karmashala/mcp/session-<uuid>.json`
  ///
  /// So a layout stored by the old code has to be repaired on the way in, or
  /// installing the fix leaves every pane the user already had just as broken.
  /// Matched on **our own** value and never on the flag alone: Codex's `-c`
  /// takes any config override, and a user's `-c model=…` is not ours to drop.
  List<String> withoutArgumentsIn(List<String> arguments) {
    switch (style) {
      case AgentMcpStyle.unsupported:
        return arguments;
      case AgentMcpStyle.configFile:
        return [
          for (final argument in arguments)
            if (!argument.startsWith('$flag=')) argument,
        ];
      case AgentMcpStyle.inlineUrl:
        final kept = <String>[];
        for (var i = 0; i < arguments.length; i++) {
          // Two tokens, dropped as two: a dangling `-c` left behind would take
          // whatever argument came next as its value.
          if (arguments[i] == flag &&
              i + 1 < arguments.length &&
              arguments[i + 1].startsWith('$urlKey=')) {
            i++;
            continue;
          }
          kept.add(arguments[i]);
        }
        return kept;
    }
  }
}

/// One model an agent can be asked for, named the way that agent names it.
///
/// [id] is the token the CLI takes — after `--model` on a command line and
/// after the in-session command — so it is never a display string dressed up:
/// a label the CLI does not know is a launch that comes up on the wrong model
/// or an in-session command that prints an error into the user's pane.
class AgentModel {
  const AgentModel({
    required this.id,
    required this.label,
    required this.summary,
  });

  /// What the CLI is given, verbatim.
  final String id;

  /// What the picker shows. Short: it also has to fit on a status bar.
  final String label;

  /// One line about what picking this actually means.
  final String summary;
}

/// How an agent CLI can be told which model to run.
enum AgentModelStyle {
  /// A flag at launch **and** a slash command inside a running session.
  liveAndAtLaunch,

  /// A flag at launch only. A running session keeps the model it started on.
  atLaunchOnly,

  /// We know which models it runs and have found no way to ask for one, so
  /// they are listed, disabled and explained rather than offered.
  listedOnly,

  /// Nothing verified. **The default.**
  unsupported,
}

/// Whether one agent can be told which model to use, and how.
///
/// Modelled exactly like [AgentMcpSupport] and [AgentForkSupport] — declared
/// data on the descriptor, [evidence] required, defaulting to the conservative
/// answer — and read the same way: nothing anywhere branches on an agent's
/// *name* to decide whether a model can be switched.
///
/// The ladder has four rungs rather than two because the two questions a model
/// control asks have different answers per CLI, and collapsing them loses the
/// one that matters:
///
/// * **Can it be told at launch?** All three shipped agents can.
/// * **Can a *running* session be moved?** Claude Code and Antigravity take an
///   in-session `/model <id>`; Codex's `/model` opens a picker and takes no
///   argument, so for Codex the honest answer is "relaunch". See
///   `built_in_agents.dart`, where each claim carries what it was read off.
///
/// [models] is a **curated list**, and that is stated rather than implied: no
/// CLI here publishes a machine-readable catalogue that this app can read
/// cheaply and per-account (Codex caches one in `$CODEX_HOME/models_cache.json`
/// and `agy models` fetches one over the network — both per-account, neither a
/// constant). Each entry below records the command its list was read from, so
/// refreshing it is a documented one-minute job rather than an archaeology
/// exercise.
class AgentModelSupport {
  /// The model rides on [flag] at launch, and [slashCommand] moves a session
  /// that is already running.
  const AgentModelSupport.liveAndAtLaunch({
    required this.flag,
    required this.slashCommand,
    required this.models,
    required this.evidence,
  }) : style = AgentModelStyle.liveAndAtLaunch;

  /// The model rides on [flag] at launch. A running session cannot be moved.
  const AgentModelSupport.atLaunchOnly({
    required this.flag,
    required this.models,
    required this.evidence,
  }) : slashCommand = '',
       style = AgentModelStyle.atLaunchOnly;

  /// The models are known; no way to ask for one is. They are listed and
  /// disabled — hiding them would leave the user wondering where the choice
  /// went, which is a different kind of silence.
  const AgentModelSupport.listedOnly({
    required this.models,
    required this.evidence,
  }) : flag = '',
       slashCommand = '',
       style = AgentModelStyle.listedOnly;

  /// Nothing verified. The default, and the answer for an agent nobody has
  /// checked — which draws no control at all rather than an empty one.
  const AgentModelSupport.unsupported()
    : flag = '',
      slashCommand = '',
      models = const [],
      evidence = '',
      style = AgentModelStyle.unsupported;

  final AgentModelStyle style;

  /// The launch option, e.g. `--model`. Empty when there is none.
  final String flag;

  /// The in-session command, e.g. `/model`. Empty when there is none.
  final String slashCommand;

  /// The models offered for this agent, best-first. Curated — see the class
  /// comment.
  final List<AgentModel> models;

  /// Where this was verified — the `--help` line, changelog entry or binary
  /// string it was read off — so a future CLI version can be re-checked rather
  /// than trusted.
  final String evidence;

  /// Whether a model can be asked for at all.
  bool get isSupported =>
      style == AgentModelStyle.liveAndAtLaunch ||
      style == AgentModelStyle.atLaunchOnly;

  /// Whether this agent has any models to show. False is what draws no chip.
  bool get isKnown => models.isNotEmpty;

  /// Whether a session already running can be moved without relaunching.
  bool get switchesLive => style == AgentModelStyle.liveAndAtLaunch;

  /// The declared model with this id, or `null` when the list does not name it.
  AgentModel? modelFor(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final model in models) {
      if (model.id == id) return model;
    }
    return null;
  }

  /// The arguments that put [modelId] on this agent's command line, or nothing.
  ///
  /// An id the list does not name is still passed. That asymmetry with the
  /// picker — which only offers what is declared — is deliberate: the row
  /// records what the user asked for, a list curated by hand goes stale, and
  /// dropping the flag would silently start the agent on a different model than
  /// the chip says it is on. The CLI is the right place for that argument to be
  /// refused, and it says so out loud.
  List<String> argumentsFor(String? modelId) =>
      isSupported && modelId != null && modelId.isNotEmpty
      ? [flag, modelId]
      : const [];

  /// The line to type into a running session to move it to [modelId], or `null`
  /// when this agent has no such command.
  ///
  /// **Never called for a session that is not idle** — that gate belongs to
  /// `SessionLauncher.setModel`, which knows the session's status; this only
  /// says what the sentence would be.
  String? commandFor(String? modelId) =>
      switchesLive && modelId != null && modelId.isNotEmpty
      ? '$slashCommand $modelId'
      : null;
}

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
      isSupported && path != null && path.isNotEmpty
      ? [token, path]
      : const [];
}

/// Executable base names to probe, per execution-environment kind. Each list is
/// tried in order and the first hit wins.
///
/// There are two lists rather than one per kind because the split that matters
/// is Windows vs POSIX: a WSL distro and a remote SSH host both run `claude`,
/// not `claude.exe`.
class AgentBinaries {
  const AgentBinaries({
    required this.windows,
    required this.posix,
    this.windowsInstallPaths = const [],
  });

  final List<String> windows;
  final List<String> posix;

  /// Exact executables to try on Windows when [windows] finds nothing on PATH,
  /// as `%VAR%`-templated absolute paths.
  ///
  /// **This is the Windows half of a compensation the POSIX branch already
  /// has.** `locateRequest` deliberately runs the POSIX lookup through a login
  /// shell so `~/.local/bin` — where these CLIs install themselves — is on
  /// PATH. Windows gets a bare `where`, which sees only the PATH the app
  /// process inherited when it started. Two things fall through that gap:
  ///
  /// * an agent whose installer never put it on PATH at all. On the machine
  ///   this was reported from, `claude.exe` sits in `%USERPROFILE%\.local\bin`
  ///   and that directory is in neither the user nor the machine PATH, so
  ///   `where claude` can never succeed;
  /// * an agent installed *after* the app process started. A process's PATH is
  ///   a snapshot taken at creation; the broadcast that tells running programs
  ///   the environment changed is one a Flutter app does not act on. Naming the
  ///   installer's own directory makes detection independent of that timing.
  ///
  /// Each entry names **one file**, never a directory to search: discovery
  /// probes exactly these paths and never walks the disk. An entry whose
  /// variables are unset is skipped rather than probed literally.
  final List<String> windowsInstallPaths;

  List<String> forKind(EnvironmentKind kind) =>
      kind == EnvironmentKind.windowsNative ? windows : posix;
}

/// How to confirm a located executable and read its version.
class AgentDiscoveryRules {
  const AgentDiscoveryRules({
    this.probeVersion = true,
    this.versionArguments = const ['--version'],
  });

  final bool probeVersion;
  final List<String> versionArguments;
}

/// How faithfully a [PermissionRisk] survives being carried onto an agent.
///
/// This used to describe the *picker*: a shared three-value mode had to be
/// translated per agent, and the translation could be lossy. It no longer is —
/// each agent declares its own modes in its own words
/// ([AgentPermissionSupport]), so anything a picker offers is exact by
/// construction.
///
/// What remains genuinely lossy is the **carry**: a handoff resolves a rung for
/// one agent and hands it to another that may have nothing at that rung. So the
/// fidelity lives on `CarriedPermission` now, which is the one place a mode
/// really is translated.
enum PermissionModeFit {
  /// The target has a mode at exactly the requested rung.
  exact,

  /// The target's nearest mode is **safer** than what was asked for. Not the
  /// same thing, and never the other direction.
  approximate,

  /// The target has nothing at or below the requested rung, or no declared
  /// modes at all.
  none,
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
/// descriptor's [evidence] in `built_in_agents.dart`. What survives the check is
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

/// The command-line vocabulary of one agent.
///
/// [resume] is the headless/protocol convention the adapters use;
/// [interactiveResume] is the one a TTY launch uses. They differ for Codex
/// (`codex --resume <id>` in app-server mode vs `codex resume <id>` in a
/// terminal), which is why both are recorded.
class AgentLaunchSpec {
  const AgentLaunchSpec({
    this.baseArguments = const [],
    this.permission = const AgentPermissionSupport.unknown(),
    this.resume = const AgentResume.unsupported(),
    this.interactiveResume = const AgentResume.unsupported(),
    this.resumeLocality = const AgentResumeLocality.launchDirectory(),
    this.sessionIdAssignment = const AgentSessionIdAssignment.unsupported(),
    this.sessionIdAnnouncement = const AgentSessionIdAnnouncement.none(),
    this.continueLatest = const AgentContinueSupport.unsupported(),
    this.prompt = const AgentPromptSupport.unsupported(),
    this.systemPromptFile = const AgentSystemPromptFileSupport.unchecked(),
    this.allowsConcurrentResume = false,
    this.resumeConflict = const AgentResumeConflictRules(),
    this.missingConversation = const AgentMissingConversationRules(),
    this.rejectedValue = const AgentRejectedValueRules.none(),
    this.fork = const AgentForkSupport.unsupported(),
    this.mcp = const AgentMcpSupport.unsupported(),
    this.model = const AgentModelSupport.unsupported(),
    this.recap = const AgentRecapSupport.unchecked(),
    this.selfUpdate = const AgentSelfUpdate.unknown(),
  });

  final List<String> baseArguments;

  /// How this agent updates itself, and how Karmashala turns that off for the
  /// processes it launches. See [AgentSelfUpdate]. Defaults to "nobody
  /// established one", which suppresses nothing.
  final AgentSelfUpdate selfUpdate;

  /// How this CLI is asked, non-interactively, to recap a conversation.
  ///
  /// Separate from [prompt] and [baseArguments] because it describes a
  /// *different process*: a recap never types into the running session, it
  /// starts the same binary in print mode and lets it exit. Defaults to
  /// unchecked, so an agent nobody has run this way offers no Recap action
  /// rather than a guessed command line.
  final AgentRecapSupport recap;

  /// This agent's own permission vocabulary, in its own words.
  ///
  /// Declared per agent because the three do not share a shape — see
  /// [AgentPermissionSupport]. Defaults to
  /// [AgentPermissionSupport.unknown], so an agent nobody has established
  /// offers nothing rather than a guess.
  final AgentPermissionSupport permission;

  final AgentResume resume;
  final AgentResume interactiveResume;

  /// Whether [resume]/[interactiveResume] still find the conversation when the
  /// CLI is launched somewhere other than where the conversation was started.
  /// See [AgentResumeLocality]; defaults to "assume not".
  final AgentResumeLocality resumeLocality;

  /// Whether a second process may resume a conversation another process is
  /// already holding.
  ///
  /// This models **whether** concurrent resume is permitted, which is a
  /// different question from [resume]/[interactiveResume]'s *how*, and the
  /// agents differ on it:
  ///
  /// * **Codex refuses.** A thread has one writer, enforced with an flock on
  ///   `~/.codex/thread-writer-locks/<thread>.lock`; a second `codex resume`
  ///   exits with `thread <id> already has an active writer (code -32600)`.
  ///   That is protection for the rollout JSONL — two writers would interleave
  ///   into one transcript — and is not something to work around.
  /// * **Claude Code permits it.** A second `claude --resume <id>` opens on the
  ///   same conversation with its history and stays usable; only its remote
  ///   control declines, in a line it prints itself.
  ///
  /// **False by default**, because the failure modes are asymmetric: refusing a
  /// resume that would have worked costs a click, while attempting one the agent
  /// forbids can corrupt the user's transcript. An agent nobody has tested is
  /// therefore treated as single-writer.
  final bool allowsConcurrentResume;

  /// What this agent prints when it refuses such a resume. Empty for an agent
  /// whose refusal we have never seen — which resolves to "no explanation",
  /// never to a guessed one.
  final AgentResumeConflictRules resumeConflict;

  /// What this agent prints when it is asked to resume a conversation it has no
  /// record of. Empty for an agent whose answer we have never seen, which
  /// resolves to "no explanation" rather than a guessed one.
  final AgentMissingConversationRules missingConversation;

  /// What this agent prints when it is handed a flag value the **installed**
  /// build does not have — the one post-mortem whose cause is a claim of ours
  /// rather than a fact about the user's conversations. See
  /// [AgentRejectedValueRules]. Empty by default.
  final AgentRejectedValueRules rejectedValue;

  /// Whether this agent can start a new conversation from an existing one's
  /// history, and how. Defaults to [AgentForkStyle.unsupported].
  final AgentForkSupport fork;

  /// Whether this agent can be pointed at Karmashala's own MCP endpoint on its
  /// command line, and how. Defaults to [AgentMcpStyle.unsupported].
  final AgentMcpSupport mcp;

  /// Whether this agent can be told which model to run, and how. Defaults to
  /// [AgentModelStyle.unsupported], which draws no model control at all.
  final AgentModelSupport model;

  /// Whether this agent will accept a session id we choose. See
  /// [AgentSessionIdAssignment].
  final AgentSessionIdAssignment sessionIdAssignment;

  /// Whether this agent says, in its own output, which session id it chose.
  /// See [AgentSessionIdAnnouncement]. Defaults to "it says nothing".
  final AgentSessionIdAnnouncement sessionIdAnnouncement;

  /// Whether this agent can be told "continue the most recent conversation",
  /// and what "most recent" is scoped to. See [AgentContinueSupport]. Defaults
  /// to unsupported.
  final AgentContinueSupport continueLatest;

  /// Whether this agent takes an opening prompt on its command line, and how.
  /// See [AgentPromptSupport]. Defaults to unsupported.
  ///
  /// This is how a session's first message is delivered: typing it into the PTY
  /// instead would race the agent's own startup, which takes seconds and shows
  /// no reliable "ready" marker.
  final AgentPromptSupport prompt;

  /// Whether this agent takes an extra system prompt as a file, and how. See
  /// [AgentSystemPromptFileSupport]. Defaults to "nobody checked".
  final AgentSystemPromptFileSupport systemPromptFile;

  /// Whether an opening prompt can be delivered at all — [prompt]'s *whether*,
  /// for the refusal gates that only ever asked that. They read the same answer
  /// they always did; what widened underneath them is the *how*.
  bool get acceptsPromptArgument => prompt.isSupported;

}

/// **How an agent updates itself, and how to stop it doing so in a
/// Karmashala-launched process.**
///
/// The behaviour this exists to defend against: a coding-agent CLI that checks
/// for a new version at startup and can replace its own executable — an npm or
/// installer self-update. Launched under an unsigned desktop app, through a
/// shell, that download-and-replace-an-exe step is the tail of a chain
/// behavioural antivirus reads as a dropper, and on the owner's managed machine
/// Bitdefender killed the whole process tree for it (docs/windows-antivirus.md).
///
/// Karmashala does not disable the user's updates in general — only in the
/// processes it launches, and only when the setting says so. Each field is
/// **declared per agent from that agent's own source or docs**, with
/// [evidence], so a version bump can be re-checked rather than trusted.
class AgentSelfUpdate {
  /// Nobody has established how this agent updates: suppress nothing, offer no
  /// update command. The conservative default.
  const AgentSelfUpdate.unknown()
    : disableArguments = const [],
      disableEnvironment = const {},
      updateCommand = const [],
      evidence = '';

  /// This agent checks for or performs updates, and can be told not to.
  ///
  /// [disableArguments] are added to the agent's own command line (Codex's
  /// global `-c check_for_update_on_startup=false`); [disableEnvironment] is
  /// layered over the launched process's environment (Claude Code's
  /// `DISABLE_AUTOUPDATER=1`). [updateCommand] is the documented command that
  /// updates the agent by hand, which Karmashala can offer to run visibly in
  /// its place.
  const AgentSelfUpdate.declared({
    this.disableArguments = const [],
    this.disableEnvironment = const {},
    this.updateCommand = const [],
    required this.evidence,
  });

  /// Global command-line arguments that stop the startup update check. They
  /// must be safe to place **left of** any resume/fork subcommand — Codex's
  /// `-c` is a global option, so it is.
  final List<String> disableArguments;

  /// Environment variables that stop the agent updating itself, layered over
  /// the launched process's environment only.
  final Map<String, String> disableEnvironment;

  /// The documented command that updates this agent by hand, executable first.
  /// Empty when none is established.
  final List<String> updateCommand;

  /// Where [disableArguments]/[disableEnvironment]/[updateCommand] were read
  /// off — the agent's source or docs, and the version. Empty for
  /// [AgentSelfUpdate.unknown].
  final String evidence;

  /// Whether anything here suppresses an update at all.
  bool get canSuppress =>
      disableArguments.isNotEmpty || disableEnvironment.isNotEmpty;

  /// Whether a manual update command is known.
  bool get hasUpdateCommand => updateCommand.isNotEmpty;
}

/// The on-disk layout of an agent's session store.
enum AgentStoreFormat {
  /// `<home>/projects/<dir>/<id>.jsonl`, read by `ClaudeStoreReader`.
  claudeJsonl,

  /// `<home>/sessions/**/rollout-*.jsonl`, read by `CodexStoreReader`.
  codexRollout,

  /// `<home>/conversations/<uuid>.db` plus the JSON, protobuf-text and SQLite
  /// side files beside it, read by `AntigravityStoreReader`.
  ///
  /// The odd one out, and the reason this is a value rather than a reuse of
  /// [none]. The other two name a **transcript** format: the file the reader
  /// opens holds the messages. This one names a store that yields *identity*
  /// without content — conversation id, working directory, title, step count,
  /// mtime — because `steps.step_payload` is protobuf in an unpublished schema
  ///.
  ///
  /// So detection, adoption and the presence probe all work for this store,
  /// and `agentSupportsChatView` still says no. That split is the whole point
  /// of the value: with [none] the sessions were invisible everywhere, which
  /// is what §6.1 was raised to fix.
  antigravityStore,

  /// A store we cannot read yet.
  none,
}

/// Where an agent keeps its per-user config and sessions.
class AgentStoreSpec {
  const AgentStoreSpec({required this.homeDirectoryName, required this.format});

  /// Directory name under the environment's home, e.g. `.claude`.
  final String homeDirectoryName;

  final AgentStoreFormat format;
}

/// The best status source an agent supports. The status service falls back down
/// the sources it actually has, so this is a preference, not an exclusive
/// choice.
enum AgentStatusStrategy { hooks, stateFile, terminalGrid, none }

/// Everything Karmashala needs to find, launch and observe one agent CLI.
///
/// This is data, not code: adding an agent means adding a descriptor. [id] is
/// the agent's identity everywhere — discovery, persistence, settings, sessions
/// and the MCP control server all key on it.
///
/// [kind] is non-null only for the agents that additionally have a hand-written
/// protocol adapter, and is read only when choosing that adapter. A descriptor
/// without one is a complete, usable agent.
class AgentDescriptor {
  const AgentDescriptor({
    required this.id,
    required this.displayName,
    this.kind,
    required this.binaries,
    this.discovery = const AgentDiscoveryRules(),
    this.launch = const AgentLaunchSpec(),
    this.store,
    this.statusStrategy = AgentStatusStrategy.none,
    this.hooks,
    this.stateFile,
    this.grid = const AgentGridRules(),
    this.approval = const AgentApprovalRules(),
    this.questions,
    this.attachments = const AgentAttachmentSupport.none(),
    this.plan = const AgentPlanSupport.none(),
    this.skills = const AgentSkillSupport.none(),
    this.mcpConfig = const AgentMcpConfigSpec.undeclared(),
  });

  final String id;
  final String displayName;
  final AgentKind? kind;
  final AgentBinaries binaries;
  final AgentDiscoveryRules discovery;
  final AgentLaunchSpec launch;
  final AgentStoreSpec? store;
  final AgentStatusStrategy statusStrategy;
  final AgentHookSpec? hooks;
  final AgentStateFileRules? stateFile;

  /// How to read this agent's status off its own TUI. Empty for an agent whose
  /// screen we have never looked at, which resolves to `unknown` rather than a
  /// guess.
  final AgentGridRules grid;

  /// Which keys answer this agent's approval prompt, when it names any.
  ///
  /// Empty for an agent whose prompt we have never read, so an approval from it
  /// is surfaced but not answerable from the chat view — which is the honest
  /// outcome, not a gap. Pressing keys into a TUI on a guess is the one failure
  /// mode worse than making the user switch to the terminal.
  final AgentApprovalRules approval;

  /// How this agent's multiple-choice questions are read and answered, or null
  /// for an agent none of whose questions were ever measured — surfaced as a
  /// session waiting on you, and answered at the terminal.
  final AgentQuestionSupport? questions;

  /// What this agent will look at when a prompt **names a file's path**.
  ///
  /// Declared data with required evidence, exactly like [AgentForkSupport], and
  /// defaulting the same conservative way. The question is narrower than "does
  /// this CLI understand pictures": Karmashala delivers a message to a running
  /// session by typing it into that session's PTY, so a launch flag the CLI
  /// has is not a door that is open once the session is up. Only a path in the
  /// prompt is.
  final AgentAttachmentSupport attachments;

  /// **Whether this agent keeps a plan for itself, and where to read it.**
  ///
  /// Declared data with required evidence, exactly like [attachments], and
  /// defaulting the same conservative way — the reasoning is at
  /// [AgentPlanSupport]. The question is narrower than "does this CLI plan":
  /// all three of them plan somehow. It is *"does it write the plan down
  /// somewhere this app can read"*, and on 2026-09-08 that had three different
  /// answers.
  final AgentPlanSupport plan;

  /// **Where this agent discovers user-level skills, and how that was
  /// learned.**
  ///
  /// Declared data with required evidence, exactly like [plan], and defaulting
  /// the same conservative way — the reasoning is at [AgentSkillSupport] and
  /// the install and uninstall story is the library doc above it. The question
  /// is not "does this CLI have skills": all three of them do. It is *where*,
  /// and on 2026-09-09 that had two different shapes.
  final AgentSkillSupport skills;

  /// **Where this agent reads its own MCP servers**, so the app can report what
  /// a session started in a directory would be given.
  ///
  /// Not [AgentLaunchSpec.mcp], which is the opposite direction: that one is
  /// how Karmashala adds *itself* to one launch. Undeclared by default, and an
  /// undeclared agent reads as unknown rather than as having none.
  final AgentMcpConfigSpec mcpConfig;

  @override
  String toString() => 'AgentDescriptor($id)';
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
  const AgentAttachmentSupport.byPath(
    this.mediaTypes, {
    required this.evidence,
  }) : refusal = '';

  final List<String> mediaTypes;

  /// Empty exactly when nothing is accepted.
  final String evidence;

  /// Why nothing is accepted, when there are words for it. Empty for an agent
  /// nobody has written a sentence about, which the phone shows as nothing
  /// rather than as a guess.
  final String refusal;

  bool get isSupported => mediaTypes.isNotEmpty;
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
/// same thing as Codex's `--last` picker, which `built_in_agents.dart` declines
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
