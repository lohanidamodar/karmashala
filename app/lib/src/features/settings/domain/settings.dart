import 'package:agent_cli/descriptors.dart' show AgentRunForm;
import 'package:karmashala_core/logging.dart';
import 'package:karmashala_devices/devices.dart';
import 'package:karmashala_ui/tokens.dart' show AppAccent, SurfaceSeparation;
import 'app_theme_mode.dart';
import 'diagnostics_settings.dart';
import 'editor_settings.dart';
import 'usage_limit_settings.dart';

/// Per-agent permission preferences in each agent's own vocabulary. Null means
/// "use the mode that agent declares as its default", never "pass no flag".
class AgentPermissions {
  const AgentPermissions({this.newSessions, this.existingSessions});

  final String? newSessions;
  final String? existingSessions;

  AgentPermissions copyWith({String? newSessions, String? existingSessions}) =>
      AgentPermissions(
        newSessions: newSessions ?? this.newSessions,
        existingSessions: existingSessions ?? this.existingSessions,
      );

  Map<String, dynamic> toJson() => {
    if (newSessions != null) 'newSessions': newSessions,
    if (existingSessions != null) 'existingSessions': existingSessions,
  };

  static AgentPermissions fromJson(Map<String, dynamic> json) =>
      AgentPermissions(
        newSessions: _selection(json['newSessions']),
        existingSessions: _selection(json['existingSessions']),
      );

  /// Reads a stored preference; the caller resolves any legacy alias itself.
  static String? _selection(Object? value) {
    if (value is! String || value.isEmpty) return null;
    return value;
  }

  /// The legacy names, still readable from a settings file written before v35.
  static const legacyNames = {'ask', 'acceptEdits', 'bypass'};

  @override
  bool operator ==(Object other) =>
      other is AgentPermissions &&
      other.newSessions == newSessions &&
      other.existingSessions == existingSessions;

  @override
  int get hashCode => Object.hash(newSessions, existingSessions);
}

/// The sidebar's width until a person drags it (UI overhaul spec §4). A
/// width already saved stays theirs.
const double kDefaultSidebarWidth = 264;

/// The old default width, which every settings file saved whether or not
/// anyone dragged. Read back as "never set", so those files get the new
/// default; any other saved width is a person's and stays.
const double _kLegacyUnsetSidebarWidth = 304;

/// [saved] as the sidebar's width: absent, not a number, or the old default
/// all mean [kDefaultSidebarWidth]. A read-time rule — the file is not
/// rewritten.
double sidebarWidthFrom(Object? saved) {
  if (saved is! num) return kDefaultSidebarWidth;
  final width = saved.toDouble();
  return width == _kLegacyUnsetSidebarWidth ? kDefaultSidebarWidth : width;
}

/// User settings: the default agent and per-agent permission preferences.
class Settings {
  const Settings({
    this.defaultAgent,
    this.defaultAgentInstallationId,
    this.permissions = const {},
    this.defaultModels = const {},
    this.flutterSdkPaths = const {},
    this.agentRunForms = const {},
    this.themeMode = AppThemeMode.system,
    this.defaultTerminalProfileId,
    this.keepAwake = false,
    this.closeToTray = false,
    this.autoStart = false,
    this.simulatorSlimming = true,
    this.simulatorSlimmingKept = kDefaultSlimmingKept,
    this.androidSlimming = true,
    this.androidSlimmingEnabled = kDefaultAndroidSlimming,
    this.androidEmulatorGpu = 'auto',
    this.androidSdkPath = '',
    this.explorerPaneWidth = kDefaultSidebarWidth,
    this.detailSidebarWidth = 320,
    this.compactDensity = true,
    this.accent = AppAccent.blue,
    this.separation = SurfaceSeparation.tones,
    this.sidebarArea,
    this.editorWordWrap = false,
    this.editorAutoSave = kDefaultEditorAutoSave,
    this.editorAutoSaveDelayMs = kDefaultEditorAutoSaveDelayMs,
    this.usageLimitBehavior = UsageLimitBehavior.schedule,
    this.resumeMessage = kDefaultResumeMessage,
    this.resumeMessages = const {},
    this.continueInterruptedTurns = true,
    this.collapsedExplorerNodes = const [],
    this.windowWidth,
    this.windowHeight,
    this.defaultSystemTerminalId,
    this.customTerminalPath,
    this.defaultCodeEditorId,
    this.customEditorPath,
    this.useInAppFilePicker,
    this.showHiddenFiles = false,
    this.launcherHotkeyJson,
    this.launcherHotkeyEnabled = true,
    this.pinnedProjectIds = const [],
    this.pinnedSessionIds = const [],
    this.shellIntegrationEnabled = false,
    this.restoreLivePanes = true,
    this.quitAsks = true,
    this.quitReopens = true,
    this.quitKeepsHostSessions = true,
    this.letAgentsUpdateThemselves,
    this.terminalChordOverrides = const {},
    this.terminalThemeSource,
    this.uiTextScale = 1.0,
    this.terminalFontSize = defaultTerminalFontSize,
    this.notesEnabled = true,
    this.hideEmptySections = true,
    this.explorerAgentFilter = const [],
    this.hiddenSidePanelSurfaces = const [],
    this.explorerProjectDetails = true,
    this.explorerEnvironmentScope = '',
    this.explorerContextScope = '',
    this.debugMode = kDefaultDebugMode,
    this.logVerbosity = LogVerbosity.normal,
    this.logToFile = true,
    this.logBufferSize = kDefaultLogBufferCapacity,
  });

  /// Must stay exactly 13: the terminal pixel goldens are painted at it.
  static const double defaultTerminalFontSize = 13.0;
  static const double minTerminalFontSize = 8.0;
  static const double maxTerminalFontSize = 28.0;

  /// Bounds for [uiTextScale] (90%–150%).
  static const double minUiTextScale = 0.9;
  static const double maxUiTextScale = 1.5;

  /// The `AgentDescriptor.id` pre-selected for a new session, or `null`.
  final String? defaultAgent;

  /// The default installation by id; preferred over [defaultAgent] while present.
  final String? defaultAgentInstallationId;

  /// Per-agent permission preferences, keyed by `AgentDescriptor.id`.
  final Map<String, AgentPermissions> permissions;

  /// Per-agent default models; an absent key passes no `--model` at all.
  final Map<String, String> defaultModels;

  /// How a new session on each agent runs, keyed by the folded agent id
  /// (`AgentRegistry.foldedIdOf`); absent reads as Terminal. The New Session
  /// card writes the last choice here, so it is both the default and the memory.
  final Map<String, String> agentRunForms;

  /// A hand-set `flutter` per `ExecutionEnvironment.id`, kept off the table
  /// discovery upserts so no sweep can overrule it (§20); absent means PATH.
  final Map<String, String> flutterSdkPaths;

  final AppThemeMode themeMode;

  /// Id of the [TerminalProfile] new terminals open with; `null` is the first.
  final String? defaultTerminalProfileId;

  final bool keepAwake;

  final bool closeToTray;

  final bool autoStart;

  /// Switch off the iOS Simulator's ~358 idle launchd services. macOS only.
  final bool simulatorSlimming;

  /// The [SlimmingCategory] ids to leave running — exceptions, not a selection.
  final List<String> simulatorSlimmingKept;

  /// Slim an Android emulator on start; only [androidSlimmingEnabled] comes on.
  final bool androidSlimming;

  /// The [AndroidSlimmingCategory] ids to apply — a selection, not exceptions.
  final List<String> androidSlimmingEnabled;

  /// [AndroidGpuMode.id] for the renderer; a string, so unknown modes survive.
  final String androidEmulatorGpu;

  /// The Android SDK a person named, or empty: tried first by the pane and
  /// the server alike (`sdkCandidateRoots`), so both reach one adb.
  final String androidSdkPath;

  final double explorerPaneWidth;
  final double detailSidebarWidth;

  final bool compactDensity;

  /// The accent selection, focus and the primary action wear (Appearance).
  final AppAccent accent;

  /// Whether regions are told apart by tone alone or with hairlines too.
  final SurfaceSeparation separation;

  /// The activity-strip area the sidebar last showed, by name; null until one
  /// is picked. A name, not the shell's enum: settings know nothing of it.
  final String? sidebarArea;

  /// Soft-wrap long lines in the in-app editor. Off by default, and the line
  /// numbers go with it: the gutter paints at a fixed row height, so a wrapped
  /// line would put every number below it against the wrong row.
  final bool editorWordWrap;

  /// When a file tab writes without being asked; see [EditorAutoSave].
  final EditorAutoSave editorAutoSave;

  /// The pause [EditorAutoSave.afterDelay] waits for, clamped when read.
  final int editorAutoSaveDelayMs;

  /// What happens when a session's turn ends on a usage limit.
  final UsageLimitBehavior usageLimitBehavior;

  /// What a scheduled resume sends by default. Empty resumes without a word.
  final String resumeMessage;

  /// The message last used per agent id, so the dialog opens on it.
  final Map<String, String> resumeMessages;

  /// Whether the server resumes a session whose turn its stop or crash cut
  /// off, and tells it so. The server reads this key itself.
  final bool continueInterruptedTurns;

  /// Explorer rows the user has folded away, by [ExplorerNode.id] — a machine,
  /// one of its sections, or a context inside it. Absent means expanded, so a
  /// machine that appears after this was written opens rather than hiding.
  final List<String> collapsedExplorerNodes;

  final double? windowWidth;
  final double? windowHeight;

  /// The terminal for "open in terminal": a detected id, `custom`, or `null`.
  final String? defaultSystemTerminalId;

  /// Custom terminal executable, when [defaultSystemTerminalId] is `custom`.
  final String? customTerminalPath;

  /// The editor for "open in editor": a detected id, `custom`, or `null`.
  final String? defaultCodeEditorId;

  /// Custom editor executable, when [defaultCodeEditorId] is `custom`.
  final String? customEditorPath;

  /// Whether "Browse…" opens Karmashala's own file browser rather than the
  /// host's dialog. **Null is not "no"** — it is "nobody has said", which each
  /// platform answers for itself: Windows in-app, macOS and Linux native.
  final bool? useInAppFilePicker;

  /// Whether every file browser — the picker, the SSH browser and the device's
  /// own — shows dot-files and hidden entries. One answer, so the same folder
  /// does not read two ways.
  final bool showHiddenFiles;

  /// The launcher hotkey as `hotkey_manager` JSON; `null` is Ctrl+Alt+Space.
  final String? launcherHotkeyJson;

  final bool launcherHotkeyEnabled;

  /// Per-chord "app or shell?" answers; absent keeps the `shellChords` default.
  final Map<String, bool> terminalChordOverrides;

  /// Project ids the user has pinned (shown first), most-recent pin last.
  final List<String> pinnedProjectIds;

  /// Pinned session ids, sorted above the rest. Metadata only.
  final List<String> pinnedSessionIds;

  /// Inject OSC 133 into new terminals. Opt-in: a failed shell is worse.
  final bool shellIntegrationEnabled;

  /// Restore last close's live panes at launch; never an agent pane.
  final bool restoreLivePanes;

  /// Whether quitting with sessions running asks first. Off, quit uses the
  /// two answers below — and still asks when it would stop a turn midway.
  final bool quitAsks;

  /// The quit question's "open these again next time", remembered.
  final bool quitReopens;

  /// Whether sessions in the session host keep running after a quit — they
  /// do unless ended, since closing a pane only disconnects from them.
  final bool quitKeepsHostSessions;

  /// Whether an agent CLI Karmashala launches may update itself in that
  /// session. **`null` means unset**, resolved by platform where it is read
  /// (`agentsMayUpdateThemselvesProvider`): default off on Windows, on
  /// elsewhere. A self-updating CLI (npm/installer download-and-replace) under
  /// an unsigned parent is a behavioural-antivirus dropper signal, and on the
  /// owner's managed Windows machine it killed the whole process tree. Off, the
  /// launched agent is passed the switch that stops its self-update; the user's
  /// own updates outside Karmashala are untouched.
  final bool? letAgentsUpdateThemselves;

  /// The terminal colour scheme: `null` for Match app, `preset:<id>` for a
  /// built-in scheme (an unknown id reads as Match app), or `<format>:<path>`
  /// for a Ghostty or Warp theme file.
  final String? terminalThemeSource;

  /// Overall UI text scale (1.0 = 100%); multiplies the OS scale, not replaces.
  final double uiTextScale;

  /// The terminal grid's font size, separate from [uiTextScale] on purpose.
  final double terminalFontSize;

  /// Whether Notes is offered at all. Off hides it and deletes nothing.
  final bool notesEnabled;

  /// Whether the Explorer folds away a saved section that is currently empty.
  final bool hideEmptySections;

  /// The `AgentDescriptor.id`s the Explorer is narrowed to, empty for "every
  /// agent". Persisted, so the header names what it is holding back.
  final List<String> explorerAgentFilter;

  /// Surfaces left out of the context panel's More menu, by
  /// `SidePanelSurface.name`, sorted. The key predates the panel's tabs.
  /// Ids, not positions, so a surface added later arrives visible; an id this
  /// build does not know is kept for the build that does.
  final List<String> hiddenSidePanelSurfaces;

  /// Whether a project row in the sidebar (once the Explorer) draws its second
  /// line — path, branch,
  /// what is running. Off is the one-line row, with those in tooltips.
  final bool explorerProjectDetails;

  /// The machine the Explorer is narrowed to, by environment id; empty is
  /// every machine. An id the workspace no longer has reads as empty.
  final String explorerEnvironmentScope;

  /// The context the Explorer is narrowed to — `ctx:<id>`, or `none` for the
  /// projects in no context; empty is every project.
  final String explorerContextScope;

  /// Debug mode: root logger to `ALL`, Logs panel shown. Never gates logging.
  final bool debugMode;

  final LogVerbosity logVerbosity;

  final bool logToFile;

  final int logBufferSize;

  bool isPinned(String projectId) => pinnedProjectIds.contains(projectId);

  bool isSessionPinned(String sessionId) =>
      pinnedSessionIds.contains(sessionId);

  AgentPermissions permissionsFor(String agentId) =>
      permissions[agentId] ?? const AgentPermissions();

  /// The model new sessions on [agentId] start on, or null to pass no flag.
  String? defaultModelFor(String agentId) => defaultModels[agentId];

  /// The `flutter` named for [environmentId], or null for "look on PATH" (§19).
  AgentRunForm runFormFor(String agentId) =>
      chosenRunFormFor(agentId) ?? AgentRunForm.terminal;

  /// The form last chosen for [agentId], or null when it never was — a
  /// default agent set to a chat form then keeps it.
  AgentRunForm? chosenRunFormFor(String agentId) {
    final name = agentRunForms[agentId];
    return name == null ? null : AgentRunForm.parse(name);
  }

  Settings withAgentRunForm(String agentId, AgentRunForm form) => copyWith(
    agentRunForms: {...agentRunForms, agentId: form.name},
  );

  String? flutterSdkPathFor(String environmentId) =>
      flutterSdkPaths[environmentId];

  Settings copyWith({
    String? defaultAgent,
    bool clearDefaultAgent = false,
    String? defaultAgentInstallationId,
    Map<String, AgentPermissions>? permissions,
    Map<String, String>? defaultModels,
    Map<String, String>? flutterSdkPaths,
    Map<String, String>? agentRunForms,
    AppThemeMode? themeMode,
    String? defaultTerminalProfileId,
    bool? keepAwake,
    bool? closeToTray,
    bool? autoStart,
    bool? simulatorSlimming,
    List<String>? simulatorSlimmingKept,
    bool? androidSlimming,
    List<String>? androidSlimmingEnabled,
    String? androidEmulatorGpu,
    String? androidSdkPath,
    double? explorerPaneWidth,
    double? detailSidebarWidth,
    bool? compactDensity,
    AppAccent? accent,
    SurfaceSeparation? separation,
    String? sidebarArea,
    bool? editorWordWrap,
    EditorAutoSave? editorAutoSave,
    int? editorAutoSaveDelayMs,
    UsageLimitBehavior? usageLimitBehavior,
    String? resumeMessage,
    Map<String, String>? resumeMessages,
    bool? continueInterruptedTurns,
    List<String>? collapsedExplorerNodes,
    double? windowWidth,
    double? windowHeight,
    String? defaultSystemTerminalId,
    String? customTerminalPath,
    String? defaultCodeEditorId,
    String? customEditorPath,
    bool? useInAppFilePicker,
    bool clearUseInAppFilePicker = false,
    bool? showHiddenFiles,
    String? launcherHotkeyJson,
    bool? launcherHotkeyEnabled,
    List<String>? pinnedProjectIds,
    List<String>? pinnedSessionIds,
    bool? shellIntegrationEnabled,
    bool? restoreLivePanes,
    bool? quitAsks,
    bool? quitReopens,
    bool? quitKeepsHostSessions,
    bool? letAgentsUpdateThemselves,
    bool clearLetAgentsUpdateThemselves = false,
    Map<String, bool>? terminalChordOverrides,
    String? terminalThemeSource,
    bool clearTerminalThemeSource = false,
    double? uiTextScale,
    double? terminalFontSize,
    bool? notesEnabled,
    bool? hideEmptySections,
    List<String>? explorerAgentFilter,
    List<String>? hiddenSidePanelSurfaces,
    bool? explorerProjectDetails,
    String? explorerEnvironmentScope,
    String? explorerContextScope,
    bool? debugMode,
    LogVerbosity? logVerbosity,
    bool? logToFile,
    int? logBufferSize,
  }) => Settings(
    defaultAgent: clearDefaultAgent
        ? null
        : (defaultAgent ?? this.defaultAgent),
    defaultAgentInstallationId: clearDefaultAgent
        ? null
        : (defaultAgentInstallationId ?? this.defaultAgentInstallationId),
    permissions: permissions ?? this.permissions,
    defaultModels: defaultModels ?? this.defaultModels,
    flutterSdkPaths: flutterSdkPaths ?? this.flutterSdkPaths,
    agentRunForms: agentRunForms ?? this.agentRunForms,
    themeMode: themeMode ?? this.themeMode,
    defaultTerminalProfileId:
        defaultTerminalProfileId ?? this.defaultTerminalProfileId,
    keepAwake: keepAwake ?? this.keepAwake,
    closeToTray: closeToTray ?? this.closeToTray,
    autoStart: autoStart ?? this.autoStart,
    simulatorSlimming: simulatorSlimming ?? this.simulatorSlimming,
    simulatorSlimmingKept: simulatorSlimmingKept ?? this.simulatorSlimmingKept,
    androidSlimming: androidSlimming ?? this.androidSlimming,
    androidSlimmingEnabled:
        androidSlimmingEnabled ?? this.androidSlimmingEnabled,
    androidEmulatorGpu: androidEmulatorGpu ?? this.androidEmulatorGpu,
    androidSdkPath: androidSdkPath ?? this.androidSdkPath,
    explorerPaneWidth: explorerPaneWidth ?? this.explorerPaneWidth,
    detailSidebarWidth: detailSidebarWidth ?? this.detailSidebarWidth,
    compactDensity: compactDensity ?? this.compactDensity,
    accent: accent ?? this.accent,
    separation: separation ?? this.separation,
    sidebarArea: sidebarArea ?? this.sidebarArea,
    editorWordWrap: editorWordWrap ?? this.editorWordWrap,
    editorAutoSave: editorAutoSave ?? this.editorAutoSave,
    editorAutoSaveDelayMs: editorAutoSaveDelayMs ?? this.editorAutoSaveDelayMs,
    usageLimitBehavior: usageLimitBehavior ?? this.usageLimitBehavior,
    resumeMessage: resumeMessage ?? this.resumeMessage,
    resumeMessages: resumeMessages ?? this.resumeMessages,
    continueInterruptedTurns:
        continueInterruptedTurns ?? this.continueInterruptedTurns,
    collapsedExplorerNodes:
        collapsedExplorerNodes ?? this.collapsedExplorerNodes,
    windowWidth: windowWidth ?? this.windowWidth,
    windowHeight: windowHeight ?? this.windowHeight,
    defaultSystemTerminalId:
        defaultSystemTerminalId ?? this.defaultSystemTerminalId,
    customTerminalPath: customTerminalPath ?? this.customTerminalPath,
    defaultCodeEditorId: defaultCodeEditorId ?? this.defaultCodeEditorId,
    customEditorPath: customEditorPath ?? this.customEditorPath,
    useInAppFilePicker: clearUseInAppFilePicker
        ? null
        : (useInAppFilePicker ?? this.useInAppFilePicker),
    showHiddenFiles: showHiddenFiles ?? this.showHiddenFiles,
    launcherHotkeyJson: launcherHotkeyJson ?? this.launcherHotkeyJson,
    launcherHotkeyEnabled: launcherHotkeyEnabled ?? this.launcherHotkeyEnabled,
    pinnedProjectIds: pinnedProjectIds ?? this.pinnedProjectIds,
    pinnedSessionIds: pinnedSessionIds ?? this.pinnedSessionIds,
    shellIntegrationEnabled:
        shellIntegrationEnabled ?? this.shellIntegrationEnabled,
    restoreLivePanes: restoreLivePanes ?? this.restoreLivePanes,
    quitAsks: quitAsks ?? this.quitAsks,
    quitReopens: quitReopens ?? this.quitReopens,
    quitKeepsHostSessions: quitKeepsHostSessions ?? this.quitKeepsHostSessions,
    letAgentsUpdateThemselves: clearLetAgentsUpdateThemselves
        ? null
        : (letAgentsUpdateThemselves ?? this.letAgentsUpdateThemselves),
    terminalChordOverrides:
        terminalChordOverrides ?? this.terminalChordOverrides,
    terminalThemeSource: clearTerminalThemeSource
        ? null
        : (terminalThemeSource ?? this.terminalThemeSource),
    uiTextScale: uiTextScale ?? this.uiTextScale,
    terminalFontSize: terminalFontSize ?? this.terminalFontSize,
    notesEnabled: notesEnabled ?? this.notesEnabled,
    hideEmptySections: hideEmptySections ?? this.hideEmptySections,
    explorerAgentFilter: explorerAgentFilter ?? this.explorerAgentFilter,
    hiddenSidePanelSurfaces:
        hiddenSidePanelSurfaces ?? this.hiddenSidePanelSurfaces,
    explorerProjectDetails:
        explorerProjectDetails ?? this.explorerProjectDetails,
    explorerEnvironmentScope:
        explorerEnvironmentScope ?? this.explorerEnvironmentScope,
    explorerContextScope: explorerContextScope ?? this.explorerContextScope,
    debugMode: debugMode ?? this.debugMode,
    logVerbosity: logVerbosity ?? this.logVerbosity,
    logToFile: logToFile ?? this.logToFile,
    logBufferSize: logBufferSize ?? this.logBufferSize,
  );

  Settings withPermissions(String agentId, AgentPermissions value) =>
      copyWith(permissions: {...permissions, agentId: value});

  /// The message a resume of [agentId] opens on: its last, else the default.
  String resumeMessageFor(String agentId) =>
      resumeMessages[agentId] ?? resumeMessage;

  Settings withResumeMessage(String agentId, String message) =>
      copyWith(resumeMessages: {...resumeMessages, agentId: message});

  /// Sets [agentId]'s default model; a null [modelId] removes the key.
  Settings withDefaultModel(String agentId, String? modelId) => copyWith(
    defaultModels: {
      for (final entry in defaultModels.entries)
        if (entry.key != agentId) entry.key: entry.value,
      if (modelId != null && modelId.isNotEmpty) agentId: modelId,
    },
  );

  /// Sets [environmentId]'s Flutter executable; a blank [path] removes the key.
  Settings withFlutterSdkPath(String environmentId, String? path) {
    final trimmed = path?.trim() ?? '';
    return copyWith(
      flutterSdkPaths: {
        for (final entry in flutterSdkPaths.entries)
          if (entry.key != environmentId) entry.key: entry.value,
        if (trimmed.isNotEmpty) environmentId: trimmed,
      },
    );
  }

  /// Every key this build reads or writes. A save replaces these and keeps
  /// the rest, so a key a newer client added survives this one's save.
  static const Set<String> jsonKeys = {
    'defaultAgent',
    'defaultAgentInstallationId',
    'themeMode',
    'defaultTerminalProfileId',
    'keepAwake',
    'closeToTray',
    'autoStart',
    'simulatorSlimming',
    'simulatorSlimmingKept',
    'androidSlimming',
    'androidSlimmingEnabled',
    'androidEmulatorGpu',
    kAndroidSdkPathSetting,
    'explorerPaneWidth',
    'detailSidebarWidth',
    'compactDensity',
    'accent',
    'separation',
    'sidebarArea',
    'editorWordWrap',
    'editorAutoSave',
    'editorAutoSaveDelayMs',
    kUsageLimitSettingKey,
    kLegacyUsageLimitSettingKey,
    'resumeMessage',
    'resumeMessages',
    'continueInterruptedTurns',
    'collapsedExplorerNodes',
    'windowWidth',
    'windowHeight',
    'defaultSystemTerminalId',
    'customTerminalPath',
    'defaultCodeEditorId',
    'customEditorPath',
    'useInAppFilePicker',
    'showHiddenFiles',
    'launcherHotkeyJson',
    'launcherHotkeyEnabled',
    'pinnedProjectIds',
    'pinnedSessionIds',
    'shellIntegrationEnabled',
    'restoreLivePanes',
    'quitAsks',
    'quitReopens',
    'quitKeepsHostSessions',
    'letAgentsUpdateThemselves',
    'terminalChordOverrides',
    'terminalThemeSource',
    'uiTextScale',
    'terminalFontSize',
    'notesEnabled',
    'hideEmptySections',
    'explorerAgentFilter',
    'hiddenSidePanelSurfaces',
    'explorerProjectDetails',
    'explorerEnvironmentScope',
    'explorerContextScope',
    'debugMode',
    'logVerbosity',
    'logToFile',
    'logBufferSize',
    'permissions',
    'defaultModels',
    'flutterSdkPaths',
    'agentRunForms',
  };

  Map<String, dynamic> toJson() => {
    if (defaultAgent != null) 'defaultAgent': defaultAgent,
    if (defaultAgentInstallationId != null)
      'defaultAgentInstallationId': defaultAgentInstallationId,
    'themeMode': themeMode.name,
    if (defaultTerminalProfileId != null)
      'defaultTerminalProfileId': defaultTerminalProfileId,
    'keepAwake': keepAwake,
    'closeToTray': closeToTray,
    'autoStart': autoStart,
    'simulatorSlimming': simulatorSlimming,
    'simulatorSlimmingKept': simulatorSlimmingKept,
    'androidSlimming': androidSlimming,
    'androidSlimmingEnabled': androidSlimmingEnabled,
    'androidEmulatorGpu': androidEmulatorGpu,
    if (androidSdkPath.isNotEmpty) kAndroidSdkPathSetting: androidSdkPath,
    // Only a width someone chose: saving the default pins it, and a later
    // default would then never reach this file (how 304 got everywhere).
    if (explorerPaneWidth != kDefaultSidebarWidth)
      'explorerPaneWidth': explorerPaneWidth,
    'detailSidebarWidth': detailSidebarWidth,
    'compactDensity': compactDensity,
    'accent': accent.name,
    'separation': separation.name,
    'sidebarArea': ?sidebarArea,
    'editorWordWrap': editorWordWrap,
    'editorAutoSave': editorAutoSave.name,
    'editorAutoSaveDelayMs': editorAutoSaveDelayMs,
    kUsageLimitSettingKey: usageLimitBehavior.name,
    'resumeMessage': resumeMessage,
    if (resumeMessages.isNotEmpty) 'resumeMessages': resumeMessages,
    'continueInterruptedTurns': continueInterruptedTurns,
    'collapsedExplorerNodes': collapsedExplorerNodes,
    if (windowWidth != null) 'windowWidth': windowWidth,
    if (windowHeight != null) 'windowHeight': windowHeight,
    if (defaultSystemTerminalId != null)
      'defaultSystemTerminalId': defaultSystemTerminalId,
    if (customTerminalPath != null) 'customTerminalPath': customTerminalPath,
    if (defaultCodeEditorId != null) 'defaultCodeEditorId': defaultCodeEditorId,
    if (customEditorPath != null) 'customEditorPath': customEditorPath,
    if (useInAppFilePicker != null) 'useInAppFilePicker': useInAppFilePicker,
    'showHiddenFiles': showHiddenFiles,
    if (launcherHotkeyJson != null) 'launcherHotkeyJson': launcherHotkeyJson,
    'launcherHotkeyEnabled': launcherHotkeyEnabled,
    'pinnedProjectIds': pinnedProjectIds,
    'pinnedSessionIds': pinnedSessionIds,
    'shellIntegrationEnabled': shellIntegrationEnabled,
    'restoreLivePanes': restoreLivePanes,
    'quitAsks': quitAsks,
    'quitReopens': quitReopens,
    'quitKeepsHostSessions': quitKeepsHostSessions,
    if (letAgentsUpdateThemselves != null)
      'letAgentsUpdateThemselves': letAgentsUpdateThemselves,
    if (terminalChordOverrides.isNotEmpty)
      'terminalChordOverrides': terminalChordOverrides,
    if (terminalThemeSource != null) 'terminalThemeSource': terminalThemeSource,
    'uiTextScale': uiTextScale,
    'terminalFontSize': terminalFontSize,
    'notesEnabled': notesEnabled,
    'hideEmptySections': hideEmptySections,
    'explorerAgentFilter': explorerAgentFilter,
    if (hiddenSidePanelSurfaces.isNotEmpty)
      'hiddenSidePanelSurfaces': hiddenSidePanelSurfaces,
    if (!explorerProjectDetails) 'explorerProjectDetails': false,
    if (explorerEnvironmentScope.isNotEmpty)
      'explorerEnvironmentScope': explorerEnvironmentScope,
    if (explorerContextScope.isNotEmpty)
      'explorerContextScope': explorerContextScope,
    'debugMode': debugMode,
    'logVerbosity': logVerbosity.name,
    'logToFile': logToFile,
    'logBufferSize': logBufferSize,
    'permissions': {
      for (final entry in permissions.entries) entry.key: entry.value.toJson(),
    },
    if (defaultModels.isNotEmpty) 'defaultModels': defaultModels,
    if (flutterSdkPaths.isNotEmpty) 'flutterSdkPaths': flutterSdkPaths,
    if (agentRunForms.isNotEmpty) 'agentRunForms': agentRunForms,
  };

  static Settings fromJson(Map<String, dynamic> json) {
    final defaultName = json['defaultAgent'];
    final defaultAgent = defaultName is String && defaultName.isNotEmpty
        ? defaultName
        : null;
    var themeMode = AppThemeMode.system;
    for (final m in AppThemeMode.values) {
      if (m.name == json['themeMode']) themeMode = m;
    }
    // Any agent id the file holds, so a new agent survives a round-trip.
    final permissions = <String, AgentPermissions>{};
    final perms = json['permissions'];
    if (perms is Map) {
      for (final entry in perms.entries) {
        final key = entry.key;
        final raw = entry.value;
        if (key is String && raw is Map<String, dynamic>) {
          permissions[key] = AgentPermissions.fromJson(raw);
        }
      }
    }
    final defaultModels = <String, String>{};
    final models = json['defaultModels'];
    if (models is Map) {
      for (final entry in models.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is String && value is String && value.isNotEmpty) {
          defaultModels[key] = value;
        }
      }
    }
    // A vanished environment keeps its entry: stopped is not removed (§19).
    final flutterSdkPaths = <String, String>{};
    final sdks = json['flutterSdkPaths'];
    if (sdks is Map) {
      for (final entry in sdks.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is String && value is String && value.isNotEmpty) {
          flutterSdkPaths[key] = value;
        }
      }
    }
    final agentRunForms = <String, String>{};
    final forms = json['agentRunForms'];
    if (forms is Map) {
      for (final entry in forms.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is String && value is String && value.isNotEmpty) {
          agentRunForms[key] = value;
        }
      }
    }
    final terminalId = json['defaultTerminalProfileId'];
    double? toDouble(Object? v) => v is num ? v.toDouble() : null;
    return Settings(
      defaultAgent: defaultAgent,
      defaultAgentInstallationId: json['defaultAgentInstallationId'] is String
          ? json['defaultAgentInstallationId'] as String
          : null,
      permissions: permissions,
      defaultModels: defaultModels,
      flutterSdkPaths: flutterSdkPaths,
      agentRunForms: agentRunForms,
      themeMode: themeMode,
      defaultTerminalProfileId: terminalId is String ? terminalId : null,
      keepAwake: json['keepAwake'] == true,
      closeToTray: json['closeToTray'] == true,
      autoStart: json['autoStart'] == true,
      // `!= false`: absent must read as on, or every install loses slimming.
      simulatorSlimming: json['simulatorSlimming'] != false,
      simulatorSlimmingKept: json['simulatorSlimmingKept'] is List
          ? (json['simulatorSlimmingKept'] as List).whereType<String>().toList()
          : kDefaultSlimmingKept,
      androidSlimming: json['androidSlimming'] != false,
      androidSlimmingEnabled: json['androidSlimmingEnabled'] is List
          ? (json['androidSlimmingEnabled'] as List)
                .whereType<String>()
                .toList()
          : kDefaultAndroidSlimming,
      androidEmulatorGpu: json['androidEmulatorGpu'] is String
          ? json['androidEmulatorGpu'] as String
          : 'auto',
      androidSdkPath: androidSdkPathIn(json) ?? '',
      explorerPaneWidth: sidebarWidthFrom(json['explorerPaneWidth']),
      detailSidebarWidth: toDouble(json['detailSidebarWidth']) ?? 320,
      collapsedExplorerNodes: json['collapsedExplorerNodes'] is List
          ? (json['collapsedExplorerNodes'] as List)
                .whereType<String>()
                .toList()
          : const [],
      compactDensity: json['compactDensity'] is bool
          ? json['compactDensity'] as bool
          : true,
      accent: AppAccent.fromName(json['accent'] as String?),
      separation: SurfaceSeparation.fromName(json['separation'] as String?),
      sidebarArea: json['sidebarArea'] as String?,
      editorWordWrap: json['editorWordWrap'] is bool
          ? json['editorWordWrap'] as bool
          : false,
      editorAutoSave: EditorAutoSave.fromName(json['editorAutoSave']),
      usageLimitBehavior: UsageLimitBehavior.fromSettingsJson(json),
      resumeMessage: json['resumeMessage'] is String
          ? json['resumeMessage'] as String
          : kDefaultResumeMessage,
      resumeMessages: {
        if (json['resumeMessages'] case final Map<dynamic, dynamic> messages)
          for (final entry in messages.entries)
            if (entry.key is String && entry.value is String)
              entry.key as String: entry.value as String,
      },
      continueInterruptedTurns: json['continueInterruptedTurns'] != false,
      editorAutoSaveDelayMs: json['editorAutoSaveDelayMs'] is int
          ? (json['editorAutoSaveDelayMs'] as int).clamp(
              kMinEditorAutoSaveDelayMs,
              kMaxEditorAutoSaveDelayMs,
            )
          : kDefaultEditorAutoSaveDelayMs,
      windowWidth: toDouble(json['windowWidth']),
      windowHeight: toDouble(json['windowHeight']),
      defaultSystemTerminalId: json['defaultSystemTerminalId'] is String
          ? json['defaultSystemTerminalId'] as String
          : null,
      customTerminalPath: json['customTerminalPath'] is String
          ? json['customTerminalPath'] as String
          : null,
      defaultCodeEditorId: json['defaultCodeEditorId'] is String
          ? json['defaultCodeEditorId'] as String
          : null,
      showHiddenFiles: json['showHiddenFiles'] as bool? ?? false,
      useInAppFilePicker: json['useInAppFilePicker'] is bool
          ? json['useInAppFilePicker'] as bool
          : null,
      customEditorPath: json['customEditorPath'] is String
          ? json['customEditorPath'] as String
          : null,
      launcherHotkeyJson: json['launcherHotkeyJson'] is String
          ? json['launcherHotkeyJson'] as String
          : null,
      launcherHotkeyEnabled: json['launcherHotkeyEnabled'] is bool
          ? json['launcherHotkeyEnabled'] as bool
          : true,
      pinnedProjectIds: json['pinnedProjectIds'] is List
          ? (json['pinnedProjectIds'] as List).whereType<String>().toList()
          : const [],
      pinnedSessionIds: json['pinnedSessionIds'] is List
          ? (json['pinnedSessionIds'] as List).whereType<String>().toList()
          : const [],
      shellIntegrationEnabled: json['shellIntegrationEnabled'] == true,
      // `!= false`: defaults on, so a file written before the key reads as on.
      restoreLivePanes: json['restoreLivePanes'] != false,
      // `!= false`: defaults on; a file that chose off keeps it.
      // `!= false`: all three default on, so an older file reads as on.
      quitAsks: json['quitAsks'] != false,
      quitReopens: json['quitReopens'] != false,
      quitKeepsHostSessions: json['quitKeepsHostSessions'] != false,
      letAgentsUpdateThemselves: json['letAgentsUpdateThemselves'] is bool
          ? json['letAgentsUpdateThemselves'] as bool
          : null,
      terminalChordOverrides: {
        if (json['terminalChordOverrides'] is Map)
          for (final entry in (json['terminalChordOverrides'] as Map).entries)
            if (entry.key is String && entry.value is bool)
              entry.key as String: entry.value as bool,
      },
      terminalThemeSource: json['terminalThemeSource'] is String
          ? json['terminalThemeSource'] as String
          : null,
      // Clamped on read: a hand-edited 0.1 leaves Settings itself unreadable.
      uiTextScale: (toDouble(json['uiTextScale']) ?? 1.0).clamp(
        minUiTextScale,
        maxUiTextScale,
      ),
      terminalFontSize:
          (toDouble(json['terminalFontSize']) ?? defaultTerminalFontSize).clamp(
            minTerminalFontSize,
            maxTerminalFontSize,
          ),
      notesEnabled: json['notesEnabled'] is bool
          ? json['notesEnabled'] as bool
          : true,
      hideEmptySections: json['hideEmptySections'] is bool
          ? json['hideEmptySections'] as bool
          : true,
      explorerAgentFilter: json['explorerAgentFilter'] is List
          ? (json['explorerAgentFilter'] as List).whereType<String>().toList()
          : const [],
      hiddenSidePanelSurfaces: json['hiddenSidePanelSurfaces'] is List
          ? ((json['hiddenSidePanelSurfaces'] as List)
                .whereType<String>()
                // `logs` is a workbench tab now, not a surface any build has.
                .where((id) => id.isNotEmpty && id != 'logs')
                .toSet()
                .toList()
              ..sort())
          : const [],
      explorerProjectDetails: json['explorerProjectDetails'] is bool
          ? json['explorerProjectDetails'] as bool
          : true,
      explorerEnvironmentScope: json['explorerEnvironmentScope'] is String
          ? json['explorerEnvironmentScope'] as String
          : '',
      explorerContextScope: json['explorerContextScope'] is String
          ? json['explorerContextScope'] as String
          : '',
      debugMode: json['debugMode'] is bool
          ? json['debugMode'] as bool
          : kDefaultDebugMode,
      logVerbosity: LogVerbosity.fromName(json['logVerbosity']),
      logToFile: json['logToFile'] is bool ? json['logToFile'] as bool : true,
      // Clamped: a hand-edited 5,000,000 would be a 40 MB array at launch.
      logBufferSize:
          (json['logBufferSize'] is int
                  ? json['logBufferSize'] as int
                  : kDefaultLogBufferCapacity)
              .clamp(kMinLogBufferCapacity, kMaxLogBufferCapacity),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Settings &&
      other.defaultAgent == defaultAgent &&
      other.defaultAgentInstallationId == defaultAgentInstallationId &&
      other.themeMode == themeMode &&
      other.defaultTerminalProfileId == defaultTerminalProfileId &&
      other.keepAwake == keepAwake &&
      other.closeToTray == closeToTray &&
      other.autoStart == autoStart &&
      other.simulatorSlimming == simulatorSlimming &&
      _listEquals(other.simulatorSlimmingKept, simulatorSlimmingKept) &&
      other.androidSlimming == androidSlimming &&
      _listEquals(other.androidSlimmingEnabled, androidSlimmingEnabled) &&
      other.androidEmulatorGpu == androidEmulatorGpu &&
      other.androidSdkPath == androidSdkPath &&
      other.explorerPaneWidth == explorerPaneWidth &&
      other.detailSidebarWidth == detailSidebarWidth &&
      other.compactDensity == compactDensity &&
      other.accent == accent &&
      other.separation == separation &&
      other.sidebarArea == sidebarArea &&
      other.editorWordWrap == editorWordWrap &&
      other.editorAutoSave == editorAutoSave &&
      other.editorAutoSaveDelayMs == editorAutoSaveDelayMs &&
      other.usageLimitBehavior == usageLimitBehavior &&
      other.resumeMessage == resumeMessage &&
      _stringMapEquals(other.resumeMessages, resumeMessages) &&
      other.continueInterruptedTurns == continueInterruptedTurns &&
      other.windowWidth == windowWidth &&
      other.windowHeight == windowHeight &&
      other.defaultSystemTerminalId == defaultSystemTerminalId &&
      other.customTerminalPath == customTerminalPath &&
      other.defaultCodeEditorId == defaultCodeEditorId &&
      other.customEditorPath == customEditorPath &&
      other.useInAppFilePicker == useInAppFilePicker &&
      other.showHiddenFiles == showHiddenFiles &&
      other.launcherHotkeyJson == launcherHotkeyJson &&
      other.launcherHotkeyEnabled == launcherHotkeyEnabled &&
      other.shellIntegrationEnabled == shellIntegrationEnabled &&
      other.restoreLivePanes == restoreLivePanes &&
      other.quitAsks == quitAsks &&
      other.quitReopens == quitReopens &&
      other.quitKeepsHostSessions == quitKeepsHostSessions &&
      other.letAgentsUpdateThemselves == letAgentsUpdateThemselves &&
      _boolMapEquals(other.terminalChordOverrides, terminalChordOverrides) &&
      other.terminalThemeSource == terminalThemeSource &&
      other.uiTextScale == uiTextScale &&
      other.terminalFontSize == terminalFontSize &&
      other.notesEnabled == notesEnabled &&
      other.hideEmptySections == hideEmptySections &&
      _listEquals(other.explorerAgentFilter, explorerAgentFilter) &&
      _listEquals(other.hiddenSidePanelSurfaces, hiddenSidePanelSurfaces) &&
      other.explorerProjectDetails == explorerProjectDetails &&
      other.explorerEnvironmentScope == explorerEnvironmentScope &&
      other.explorerContextScope == explorerContextScope &&
      other.debugMode == debugMode &&
      other.logVerbosity == logVerbosity &&
      other.logToFile == logToFile &&
      other.logBufferSize == logBufferSize &&
      _listEquals(other.pinnedProjectIds, pinnedProjectIds) &&
      _listEquals(other.collapsedExplorerNodes, collapsedExplorerNodes) &&
      _listEquals(other.pinnedSessionIds, pinnedSessionIds) &&
      _mapEquals(other.permissions, permissions) &&
      _stringMapEquals(other.defaultModels, defaultModels) &&
      _stringMapEquals(other.flutterSdkPaths, flutterSdkPaths) &&
      _stringMapEquals(other.agentRunForms, agentRunForms);

  @override
  int get hashCode => Object.hash(
    defaultAgent,
    themeMode,
    defaultTerminalProfileId,
    keepAwake,
    closeToTray,
    autoStart,
    simulatorSlimming,
    Object.hashAll(simulatorSlimmingKept),
    explorerPaneWidth,
    detailSidebarWidth,
    compactDensity,
    Object.hash(accent, separation, sidebarArea, windowWidth, windowHeight),
    defaultSystemTerminalId,
    customTerminalPath,
    defaultCodeEditorId,
    customEditorPath,
    Object.hash(
      Object.hash(
        Object.hashAll(pinnedProjectIds),
        Object.hashAll(collapsedExplorerNodes),
      ),
      Object.hashAll(pinnedSessionIds),
      launcherHotkeyJson,
      launcherHotkeyEnabled,
      defaultAgentInstallationId,
      shellIntegrationEnabled,
      restoreLivePanes,
      terminalThemeSource,
      uiTextScale,
      terminalFontSize,
      notesEnabled,
      debugMode,
      logVerbosity,
      logToFile,
      logBufferSize,
      // Folded in: the outer call is already at `Object.hash`'s 20-arg limit.
      Object.hash(
        letAgentsUpdateThemselves,
        useInAppFilePicker,
        showHiddenFiles,
        androidSlimming,
        editorWordWrap,
        editorAutoSave,
        editorAutoSaveDelayMs,
        Object.hash(
          quitAsks,
          quitReopens,
          quitKeepsHostSessions,
          usageLimitBehavior,
          resumeMessage,
          continueInterruptedTurns,
          Object.hashAllUnordered(
            resumeMessages.entries.map((e) => Object.hash(e.key, e.value)),
          ),
        ),
        hideEmptySections,
        Object.hashAll(explorerAgentFilter),
        Object.hashAll(hiddenSidePanelSurfaces),
        explorerProjectDetails,
        explorerEnvironmentScope,
        explorerContextScope,
        Object.hashAll(androidSlimmingEnabled),
        androidEmulatorGpu,
        androidSdkPath,
        Object.hashAllUnordered(
          defaultModels.entries.map((e) => Object.hash(e.key, e.value)),
        ),
        Object.hashAllUnordered(
          flutterSdkPaths.entries.map((e) => Object.hash(e.key, e.value)),
        ),
      ),
    ),
    Object.hashAllUnordered(
      permissions.entries.map((e) => Object.hash(e.key, e.value)),
    ),
    Object.hashAllUnordered(
      terminalChordOverrides.entries.map((e) => Object.hash(e.key, e.value)),
    ),
    Object.hashAllUnordered(
      agentRunForms.entries.map((e) => Object.hash(e.key, e.value)),
    ),
  );

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _stringMapEquals(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  static bool _boolMapEquals(Map<String, bool> a, Map<String, bool> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  static bool _mapEquals(
    Map<String, AgentPermissions> a,
    Map<String, AgentPermissions> b,
  ) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }
}
