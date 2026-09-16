import 'package:karmashala_core/logging.dart';
import 'package:karmashala_devices/devices.dart';
import 'app_theme_mode.dart';
import 'diagnostics_settings.dart';

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

/// User settings: the default agent and per-agent permission preferences.
class Settings {
  const Settings({
    this.defaultAgent,
    this.defaultAgentInstallationId,
    this.permissions = const {},
    this.defaultModels = const {},
    this.flutterSdkPaths = const {},
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
    this.explorerPaneWidth = 304,
    this.detailSidebarWidth = 320,
    this.compactDensity = true,
    this.editorWordWrap = false,
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
    this.hostBackedLocalPanes = false,
    this.terminalChordOverrides = const {},
    this.terminalThemeSource,
    this.remoteAccessEnabled = false,
    this.remoteRelayUrl,
    this.localRelayPort = 8787,
    this.uiTextScale = 1.0,
    this.terminalFontSize = defaultTerminalFontSize,
    this.notesEnabled = true,
    this.hideEmptySections = true,
    this.explorerAgentFilter = const [],
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

  final double explorerPaneWidth;
  final double detailSidebarWidth;

  final bool compactDensity;

  /// Soft-wrap long lines in the in-app editor. Off by default, and the line
  /// numbers go with it: the gutter paints at a fixed row height, so a wrapped
  /// line would put every number below it against the wrong row.
  final bool editorWordWrap;

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

  /// Run a local pane's shell under `karmashala_host` so it outlives the app.
  /// Off by default: there is no OSC 133 on that path, so a host-backed pane
  /// reports no command boundaries and `terminal_run` claims no exit code.
  final bool hostBackedLocalPanes;

  /// The imported terminal theme as `<format>:<path>`, or `null` for built-in.
  final String? terminalThemeSource;

  /// Whether the mobile-companion host runs. Off: nothing listens or dials.
  final bool remoteAccessEnabled;

  /// The relay the host dials, or `null` for the PopupBits default.
  final String? remoteRelayUrl;

  /// The embedded relay's port; the default matches the relay package's own.
  final int localRelayPort;

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
  String? flutterSdkPathFor(String environmentId) =>
      flutterSdkPaths[environmentId];

  Settings copyWith({
    String? defaultAgent,
    bool clearDefaultAgent = false,
    String? defaultAgentInstallationId,
    Map<String, AgentPermissions>? permissions,
    Map<String, String>? defaultModels,
    Map<String, String>? flutterSdkPaths,
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
    double? explorerPaneWidth,
    double? detailSidebarWidth,
    bool? compactDensity,
    bool? editorWordWrap,
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
    bool? hostBackedLocalPanes,
    Map<String, bool>? terminalChordOverrides,
    String? terminalThemeSource,
    bool clearTerminalThemeSource = false,
    bool? remoteAccessEnabled,
    String? remoteRelayUrl,
    bool clearRemoteRelayUrl = false,
    int? localRelayPort,
    double? uiTextScale,
    double? terminalFontSize,
    bool? notesEnabled,
    bool? hideEmptySections,
    List<String>? explorerAgentFilter,
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
    explorerPaneWidth: explorerPaneWidth ?? this.explorerPaneWidth,
    detailSidebarWidth: detailSidebarWidth ?? this.detailSidebarWidth,
    compactDensity: compactDensity ?? this.compactDensity,
    editorWordWrap: editorWordWrap ?? this.editorWordWrap,
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
    hostBackedLocalPanes: hostBackedLocalPanes ?? this.hostBackedLocalPanes,
    terminalChordOverrides:
        terminalChordOverrides ?? this.terminalChordOverrides,
    terminalThemeSource: clearTerminalThemeSource
        ? null
        : (terminalThemeSource ?? this.terminalThemeSource),
    remoteAccessEnabled: remoteAccessEnabled ?? this.remoteAccessEnabled,
    remoteRelayUrl: clearRemoteRelayUrl
        ? null
        : (remoteRelayUrl ?? this.remoteRelayUrl),
    localRelayPort: localRelayPort ?? this.localRelayPort,
    uiTextScale: uiTextScale ?? this.uiTextScale,
    terminalFontSize: terminalFontSize ?? this.terminalFontSize,
    notesEnabled: notesEnabled ?? this.notesEnabled,
    hideEmptySections: hideEmptySections ?? this.hideEmptySections,
    explorerAgentFilter: explorerAgentFilter ?? this.explorerAgentFilter,
    debugMode: debugMode ?? this.debugMode,
    logVerbosity: logVerbosity ?? this.logVerbosity,
    logToFile: logToFile ?? this.logToFile,
    logBufferSize: logBufferSize ?? this.logBufferSize,
  );

  Settings withPermissions(String agentId, AgentPermissions value) =>
      copyWith(permissions: {...permissions, agentId: value});

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
    'explorerPaneWidth': explorerPaneWidth,
    'detailSidebarWidth': detailSidebarWidth,
    'compactDensity': compactDensity,
    'editorWordWrap': editorWordWrap,
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
    'hostBackedLocalPanes': hostBackedLocalPanes,
    if (terminalChordOverrides.isNotEmpty)
      'terminalChordOverrides': terminalChordOverrides,
    if (terminalThemeSource != null) 'terminalThemeSource': terminalThemeSource,
    'remoteAccessEnabled': remoteAccessEnabled,
    if (remoteRelayUrl != null) 'remoteRelayUrl': remoteRelayUrl,
    'localRelayPort': localRelayPort,
    'uiTextScale': uiTextScale,
    'terminalFontSize': terminalFontSize,
    'notesEnabled': notesEnabled,
    'hideEmptySections': hideEmptySections,
    'explorerAgentFilter': explorerAgentFilter,
    'debugMode': debugMode,
    'logVerbosity': logVerbosity.name,
    'logToFile': logToFile,
    'logBufferSize': logBufferSize,
    'permissions': {
      for (final entry in permissions.entries) entry.key: entry.value.toJson(),
    },
    if (defaultModels.isNotEmpty) 'defaultModels': defaultModels,
    if (flutterSdkPaths.isNotEmpty) 'flutterSdkPaths': flutterSdkPaths,
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
      themeMode: themeMode,
      defaultTerminalProfileId: terminalId is String ? terminalId : null,
      keepAwake: json['keepAwake'] == true,
      closeToTray: json['closeToTray'] == true,
      autoStart: json['autoStart'] == true,
      // `!= false`: absent must read as on, or every install loses slimming.
      simulatorSlimming: json['simulatorSlimming'] != false,
      simulatorSlimmingKept: json['simulatorSlimmingKept'] is List
          ? (json['simulatorSlimmingKept'] as List)
                .whereType<String>()
                .toList()
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
      explorerPaneWidth: toDouble(json['explorerPaneWidth']) ?? 304,
      detailSidebarWidth: toDouble(json['detailSidebarWidth']) ?? 320,
      collapsedExplorerNodes: json['collapsedExplorerNodes'] is List
          ? (json['collapsedExplorerNodes'] as List)
                .whereType<String>()
                .toList()
          : const [],
      compactDensity: json['compactDensity'] is bool
          ? json['compactDensity'] as bool
          : true,
      editorWordWrap: json['editorWordWrap'] is bool
          ? json['editorWordWrap'] as bool
          : false,
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
      // `== true`: defaults off, so an older file reads as off.
      hostBackedLocalPanes: json['hostBackedLocalPanes'] == true,
      terminalChordOverrides: {
        if (json['terminalChordOverrides'] is Map)
          for (final entry in (json['terminalChordOverrides'] as Map).entries)
            if (entry.key is String && entry.value is bool)
              entry.key as String: entry.value as bool,
      },
      terminalThemeSource: json['terminalThemeSource'] is String
          ? json['terminalThemeSource'] as String
          : null,
      remoteAccessEnabled: json['remoteAccessEnabled'] == true,
      remoteRelayUrl: json['remoteRelayUrl'] is String
          ? json['remoteRelayUrl'] as String
          : null,
      localRelayPort: json['localRelayPort'] is int
          ? json['localRelayPort'] as int
          : 8787,
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
      other.explorerPaneWidth == explorerPaneWidth &&
      other.detailSidebarWidth == detailSidebarWidth &&
      other.compactDensity == compactDensity &&
      other.editorWordWrap == editorWordWrap &&
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
      other.hostBackedLocalPanes == hostBackedLocalPanes &&
      _boolMapEquals(other.terminalChordOverrides, terminalChordOverrides) &&
      other.terminalThemeSource == terminalThemeSource &&
      other.remoteAccessEnabled == remoteAccessEnabled &&
      other.remoteRelayUrl == remoteRelayUrl &&
      other.localRelayPort == localRelayPort &&
      other.uiTextScale == uiTextScale &&
      other.terminalFontSize == terminalFontSize &&
      other.notesEnabled == notesEnabled &&
      other.hideEmptySections == hideEmptySections &&
      _listEquals(other.explorerAgentFilter, explorerAgentFilter) &&
      other.debugMode == debugMode &&
      other.logVerbosity == logVerbosity &&
      other.logToFile == logToFile &&
      other.logBufferSize == logBufferSize &&
      _listEquals(other.pinnedProjectIds, pinnedProjectIds) &&
      _listEquals(other.collapsedExplorerNodes, collapsedExplorerNodes) &&
      _listEquals(other.pinnedSessionIds, pinnedSessionIds) &&
      _mapEquals(other.permissions, permissions) &&
      _stringMapEquals(other.defaultModels, defaultModels) &&
      _stringMapEquals(other.flutterSdkPaths, flutterSdkPaths);

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
    windowWidth,
    windowHeight,
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
      remoteAccessEnabled,
      remoteRelayUrl,
      localRelayPort,
      uiTextScale,
      terminalFontSize,
      notesEnabled,
      debugMode,
      logVerbosity,
      logToFile,
      logBufferSize,
      // Folded in: the outer call is already at `Object.hash`'s 20-arg limit.
      Object.hash(
        hostBackedLocalPanes,
        useInAppFilePicker,
        showHiddenFiles,
        androidSlimming,
        editorWordWrap,
        hideEmptySections,
        Object.hashAll(explorerAgentFilter),
        Object.hashAll(androidSlimmingEnabled),
        androidEmulatorGpu,
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
