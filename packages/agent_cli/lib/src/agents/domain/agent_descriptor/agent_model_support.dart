part of '../agent_descriptor.dart';

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
///   each agent's descriptor, where each claim carries what it was read off.
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
  }) : pickerCommand = '',
       style = AgentModelStyle.liveAndAtLaunch;

  /// The model rides on [flag] at launch. A running session cannot be moved.
  const AgentModelSupport.atLaunchOnly({
    required this.flag,
    required this.models,
    required this.evidence,
    this.pickerCommand = '',
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
       pickerCommand = '',
       style = AgentModelStyle.listedOnly;

  const AgentModelSupport._(
    this.style,
    this.flag,
    this.slashCommand,
    this.models,
    this.evidence,
    this.pickerCommand,
  );

  /// The same support offering [found] — the list the CLI itself reported for
  /// this account — in place of the curated one. How a model is asked for does
  /// not change with which models there are.
  AgentModelSupport withModels(List<AgentModel> found) => AgentModelSupport._(
    style,
    flag,
    slashCommand,
    List.unmodifiable(found),
    evidence,
    pickerCommand,
  );

  /// Nothing verified. The default, and the answer for an agent nobody has
  /// checked — which draws no control at all rather than an empty one.
  const AgentModelSupport.unsupported()
    : flag = '',
      slashCommand = '',
      models = const [],
      evidence = '',
      pickerCommand = '',
      style = AgentModelStyle.unsupported;

  final AgentModelStyle style;

  /// An in-session command that opens the agent's **own** model picker, for an
  /// agent whose model cannot be named in a running session. Empty when none.
  final String pickerCommand;

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
