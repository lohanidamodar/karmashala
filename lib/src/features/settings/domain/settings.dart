import '../../../core/logging/log_buffer.dart';
import 'app_theme_mode.dart';
import 'diagnostics_settings.dart';
import 'permission_mode.dart';
import 'relay_mode.dart';

/// Per-agent permission preferences for new vs. existing sessions.
class AgentPermissions {
  const AgentPermissions({
    this.newSessions = PermissionMode.ask,
    this.existingSessions = PermissionMode.ask,
  });

  final PermissionMode newSessions;
  final PermissionMode existingSessions;

  AgentPermissions copyWith({
    PermissionMode? newSessions,
    PermissionMode? existingSessions,
  }) => AgentPermissions(
    newSessions: newSessions ?? this.newSessions,
    existingSessions: existingSessions ?? this.existingSessions,
  );

  Map<String, dynamic> toJson() => {
    'newSessions': newSessions.name,
    'existingSessions': existingSessions.name,
  };

  static AgentPermissions fromJson(Map<String, dynamic> json) =>
      AgentPermissions(
        newSessions: _mode(json['newSessions']),
        existingSessions: _mode(json['existingSessions']),
      );

  static PermissionMode _mode(Object? value) {
    for (final m in PermissionMode.values) {
      if (m.name == value) return m;
    }
    return PermissionMode.ask;
  }

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
    this.themeMode = AppThemeMode.system,
    this.defaultTerminalProfileId,
    this.keepAwake = false,
    this.closeToTray = false,
    this.autoStart = false,
    this.explorerPaneWidth = 304,
    this.detailSidebarWidth = 320,
    this.compactDensity = true,
    this.windowWidth,
    this.windowHeight,
    this.defaultSystemTerminalId,
    this.customTerminalPath,
    this.defaultCodeEditorId,
    this.customEditorPath,
    this.launcherHotkeyJson,
    this.launcherHotkeyEnabled = true,
    this.pinnedProjectIds = const [],
    this.pinnedSessionIds = const [],
    this.shellIntegrationEnabled = false,
    this.terminalChordOverrides = const {},
    this.terminalThemeSource,
    this.remoteAccessEnabled = false,
    this.remoteRelayUrl,
    this.remoteRelayMode = RelayMode.hosted,
    this.localRelayPort = 8787,
    this.uiTextScale = 1.0,
    this.terminalFontSize = defaultTerminalFontSize,
    this.debugMode = kDefaultDebugMode,
    this.logVerbosity = LogVerbosity.normal,
    this.logToFile = true,
    this.logBufferSize = kDefaultLogBufferCapacity,
  });

  /// The terminal font size the app shipped with — the hardcoded 13 the pane
  /// used before this was a setting. The default must stay exactly this value:
  /// the terminal pixel goldens are painted at it.
  static const double defaultTerminalFontSize = 13.0;
  static const double minTerminalFontSize = 8.0;
  static const double maxTerminalFontSize = 28.0;

  /// Bounds for [uiTextScale] (90%–150%).
  static const double minUiTextScale = 0.9;
  static const double maxUiTextScale = 1.5;

  /// The `AgentDescriptor.id` of the agent pre-selected when starting a new
  /// session, or `null` for none. Kept in sync with
  /// [defaultAgentInstallationId].
  final String? defaultAgent;

  /// The specific installation chosen as default (e.g. Claude on WSL vs Claude
  /// on Windows), by installation id. Preferred over [defaultAgent] when the
  /// installation is still present; falls back to the kind otherwise.
  final String? defaultAgentInstallationId;

  /// Per-agent permission preferences, keyed by `AgentDescriptor.id` (defaults
  /// to "ask" when absent).
  final Map<String, AgentPermissions> permissions;

  /// The app theme preference.
  final AppThemeMode themeMode;

  /// Id of the [TerminalProfile] new terminals open with, or `null` to use the
  /// first available (PowerShell). Stored as an id so it survives across runs.
  final String? defaultTerminalProfileId;

  /// Keep the system (and display) awake while the app runs.
  final bool keepAwake;

  /// Hide to the system tray on window close instead of quitting.
  final bool closeToTray;

  /// Launch the app automatically when the user logs in.
  final bool autoStart;

  /// Persisted width of the Explorer pane and the detail sidebar.
  final double explorerPaneWidth;
  final double detailSidebarWidth;

  /// Compact UI density (denser lists/controls) when true.
  final bool compactDensity;

  /// Last window size, restored on launch (null until first saved).
  final double? windowWidth;
  final double? windowHeight;

  /// The external terminal app used to resume sessions ("open in terminal"):
  /// a detected terminal id (`windowsTerminal`, …), the sentinel
  /// `custom`, or `null` to use the first detected one.
  final String? defaultSystemTerminalId;

  /// Path to a custom terminal executable, used when
  /// [defaultSystemTerminalId] is `custom`.
  final String? customTerminalPath;

  /// The code editor used to open a project/folder ("open in editor"): a
  /// detected editor id (`vscode`, `zed`), the sentinel `custom`, or `null` to
  /// use the first detected one.
  final String? defaultCodeEditorId;

  /// Path to a custom editor executable, used when [defaultCodeEditorId] is
  /// `custom`.
  final String? customEditorPath;

  /// The global hotkey that summons the window with quick open up, as the
  /// encoded JSON of a `hotkey_manager` HotKey. `null` means the built-in default
  /// (Ctrl+Alt+Space). Stored as an opaque string so this domain stays free of
  /// the hotkey package.
  final String? launcherHotkeyJson;

  /// Whether the global launcher hotkey is registered at all.
  final bool launcherHotkeyEnabled;

  /// Per-chord answers to "does a focused terminal pane give this key to the
  /// app, or to the shell?", keyed by the chord's label (`Ctrl+K`). A chord
  /// with no entry keeps the default declared in `shellChords`.
  ///
  /// A map rather than a list because the question has two directions: `Ctrl+B`
  /// is the tmux prefix and ships going to the shell, and someone who does not
  /// live in tmux may well want it back for the Explorer.
  final Map<String, bool> terminalChordOverrides;

  /// Project ids the user has pinned (shown first), most-recent pin last.
  final List<String> pinnedProjectIds;

  /// Session ids (native or imported) the user has pinned within their project;
  /// pinned sessions sort above the rest. Stored as metadata — the sessions
  /// themselves stay sourced live from the CLI agents.
  final List<String> pinnedSessionIds;

  /// Inject OSC 133 shell integration into new terminals, giving command
  /// boundaries, exit codes and durations.
  ///
  /// Off by default and read at pane-launch time. A shell that fails to start
  /// is a much worse outcome than a missing feature, so this stays opt-in.
  final bool shellIntegrationEnabled;

  /// The imported terminal colour theme, as `<format>:<path>` (for example
  /// `warp:C:\\Users\\a\\...\\nord.yaml`), or `null` for the built-in theme.
  ///
  /// The identity is stored rather than the resolved colours, so editing the
  /// theme file is picked up. A file that later disappears or breaks falls back
  /// to the built-in theme with a readable error.
  final String? terminalThemeSource;

  /// Whether the mobile-companion host runs. Off by default: nothing listens,
  /// nothing dials, until the user turns it on.
  final bool remoteAccessEnabled;

  /// The relay the host dials, or `null` for the PopupBits default. Stored as
  /// text so this domain stays free of the remote feature.
  final String? remoteRelayUrl;

  /// Whether remote access runs through the embedded local relay or a hosted
  /// one. Hosted by default, matching what existed before the choice did.
  final RelayMode remoteRelayMode;

  /// The port the embedded local relay binds. The default matches the relay
  /// package's own (pinned by a test there, so the two cannot drift).
  final int localRelayPort;

  /// Overall UI text scale (1.0 = 100%), applied at the app root through
  /// `MediaQuery`'s textScaler so menus, dialogs and tooltips follow too.
  /// Multiplies the OS text scale rather than replacing it.
  final double uiTextScale;

  /// The terminal grid's font size, separate from [uiTextScale] on purpose:
  /// terminal density and UI legibility are different preferences.
  final double terminalFontSize;

  /// Whether debug mode is on: the root logger drops to `ALL` and the Logs
  /// panel appears on the side-panel rail.
  ///
  /// It does **not** control whether logging happens — warnings and errors are
  /// recorded either way, because a buffer that starts filling when you open
  /// the panel is a buffer that makes you reproduce the bug first.
  final bool debugMode;

  /// How much of the log is written to the file on disk.
  final LogVerbosity logVerbosity;

  /// Whether the rotating log file is written at all.
  final bool logToFile;

  /// How many records the in-memory tail keeps.
  final int logBufferSize;

  bool isPinned(String projectId) => pinnedProjectIds.contains(projectId);

  bool isSessionPinned(String sessionId) =>
      pinnedSessionIds.contains(sessionId);

  AgentPermissions permissionsFor(String agentId) =>
      permissions[agentId] ?? const AgentPermissions();

  Settings copyWith({
    String? defaultAgent,
    bool clearDefaultAgent = false,
    String? defaultAgentInstallationId,
    Map<String, AgentPermissions>? permissions,
    AppThemeMode? themeMode,
    String? defaultTerminalProfileId,
    bool? keepAwake,
    bool? closeToTray,
    bool? autoStart,
    double? explorerPaneWidth,
    double? detailSidebarWidth,
    bool? compactDensity,
    double? windowWidth,
    double? windowHeight,
    String? defaultSystemTerminalId,
    String? customTerminalPath,
    String? defaultCodeEditorId,
    String? customEditorPath,
    String? launcherHotkeyJson,
    bool? launcherHotkeyEnabled,
    List<String>? pinnedProjectIds,
    List<String>? pinnedSessionIds,
    bool? shellIntegrationEnabled,
    Map<String, bool>? terminalChordOverrides,
    String? terminalThemeSource,
    bool clearTerminalThemeSource = false,
    bool? remoteAccessEnabled,
    String? remoteRelayUrl,
    bool clearRemoteRelayUrl = false,
    RelayMode? remoteRelayMode,
    int? localRelayPort,
    double? uiTextScale,
    double? terminalFontSize,
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
    themeMode: themeMode ?? this.themeMode,
    defaultTerminalProfileId:
        defaultTerminalProfileId ?? this.defaultTerminalProfileId,
    keepAwake: keepAwake ?? this.keepAwake,
    closeToTray: closeToTray ?? this.closeToTray,
    autoStart: autoStart ?? this.autoStart,
    explorerPaneWidth: explorerPaneWidth ?? this.explorerPaneWidth,
    detailSidebarWidth: detailSidebarWidth ?? this.detailSidebarWidth,
    compactDensity: compactDensity ?? this.compactDensity,
    windowWidth: windowWidth ?? this.windowWidth,
    windowHeight: windowHeight ?? this.windowHeight,
    defaultSystemTerminalId:
        defaultSystemTerminalId ?? this.defaultSystemTerminalId,
    customTerminalPath: customTerminalPath ?? this.customTerminalPath,
    defaultCodeEditorId: defaultCodeEditorId ?? this.defaultCodeEditorId,
    customEditorPath: customEditorPath ?? this.customEditorPath,
    launcherHotkeyJson: launcherHotkeyJson ?? this.launcherHotkeyJson,
    launcherHotkeyEnabled: launcherHotkeyEnabled ?? this.launcherHotkeyEnabled,
    pinnedProjectIds: pinnedProjectIds ?? this.pinnedProjectIds,
    pinnedSessionIds: pinnedSessionIds ?? this.pinnedSessionIds,
    shellIntegrationEnabled:
        shellIntegrationEnabled ?? this.shellIntegrationEnabled,
    terminalChordOverrides:
        terminalChordOverrides ?? this.terminalChordOverrides,
    terminalThemeSource: clearTerminalThemeSource
        ? null
        : (terminalThemeSource ?? this.terminalThemeSource),
    remoteAccessEnabled: remoteAccessEnabled ?? this.remoteAccessEnabled,
    remoteRelayUrl: clearRemoteRelayUrl
        ? null
        : (remoteRelayUrl ?? this.remoteRelayUrl),
    remoteRelayMode: remoteRelayMode ?? this.remoteRelayMode,
    localRelayPort: localRelayPort ?? this.localRelayPort,
    uiTextScale: uiTextScale ?? this.uiTextScale,
    terminalFontSize: terminalFontSize ?? this.terminalFontSize,
    debugMode: debugMode ?? this.debugMode,
    logVerbosity: logVerbosity ?? this.logVerbosity,
    logToFile: logToFile ?? this.logToFile,
    logBufferSize: logBufferSize ?? this.logBufferSize,
  );

  Settings withPermissions(String agentId, AgentPermissions value) =>
      copyWith(permissions: {...permissions, agentId: value});

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
    'explorerPaneWidth': explorerPaneWidth,
    'detailSidebarWidth': detailSidebarWidth,
    'compactDensity': compactDensity,
    if (windowWidth != null) 'windowWidth': windowWidth,
    if (windowHeight != null) 'windowHeight': windowHeight,
    if (defaultSystemTerminalId != null)
      'defaultSystemTerminalId': defaultSystemTerminalId,
    if (customTerminalPath != null) 'customTerminalPath': customTerminalPath,
    if (defaultCodeEditorId != null) 'defaultCodeEditorId': defaultCodeEditorId,
    if (customEditorPath != null) 'customEditorPath': customEditorPath,
    if (launcherHotkeyJson != null) 'launcherHotkeyJson': launcherHotkeyJson,
    'launcherHotkeyEnabled': launcherHotkeyEnabled,
    'pinnedProjectIds': pinnedProjectIds,
    'pinnedSessionIds': pinnedSessionIds,
    'shellIntegrationEnabled': shellIntegrationEnabled,
    if (terminalChordOverrides.isNotEmpty)
      'terminalChordOverrides': terminalChordOverrides,
    if (terminalThemeSource != null) 'terminalThemeSource': terminalThemeSource,
    'remoteAccessEnabled': remoteAccessEnabled,
    if (remoteRelayUrl != null) 'remoteRelayUrl': remoteRelayUrl,
    'remoteRelayMode': remoteRelayMode.name,
    'localRelayPort': localRelayPort,
    'uiTextScale': uiTextScale,
    'terminalFontSize': terminalFontSize,
    'debugMode': debugMode,
    'logVerbosity': logVerbosity.name,
    'logToFile': logToFile,
    'logBufferSize': logBufferSize,
    'permissions': {
      for (final entry in permissions.entries) entry.key: entry.value.toJson(),
    },
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
    // Read whatever agent ids the file holds rather than a fixed list, so a
    // newly registered agent's preferences survive a round-trip.
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
    final terminalId = json['defaultTerminalProfileId'];
    double? toDouble(Object? v) => v is num ? v.toDouble() : null;
    return Settings(
      defaultAgent: defaultAgent,
      defaultAgentInstallationId: json['defaultAgentInstallationId'] is String
          ? json['defaultAgentInstallationId'] as String
          : null,
      permissions: permissions,
      themeMode: themeMode,
      defaultTerminalProfileId: terminalId is String ? terminalId : null,
      keepAwake: json['keepAwake'] == true,
      closeToTray: json['closeToTray'] == true,
      autoStart: json['autoStart'] == true,
      explorerPaneWidth: toDouble(json['explorerPaneWidth']) ?? 304,
      detailSidebarWidth: toDouble(json['detailSidebarWidth']) ?? 320,
      compactDensity: json['compactDensity'] is bool
          ? json['compactDensity'] as bool
          : true,
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
      remoteRelayMode: RelayMode.values.firstWhere(
        (m) => m.name == json['remoteRelayMode'],
        orElse: () => RelayMode.hosted,
      ),
      localRelayPort: json['localRelayPort'] is int
          ? json['localRelayPort'] as int
          : 8787,
      // Clamped on read: a hand-edited 0.1 would make the whole UI unusable,
      // and Settings is the only screen it could be fixed from.
      uiTextScale: (toDouble(json['uiTextScale']) ?? 1.0).clamp(
        minUiTextScale,
        maxUiTextScale,
      ),
      terminalFontSize:
          (toDouble(json['terminalFontSize']) ?? defaultTerminalFontSize).clamp(
            minTerminalFontSize,
            maxTerminalFontSize,
          ),
      debugMode: json['debugMode'] is bool
          ? json['debugMode'] as bool
          : kDefaultDebugMode,
      logVerbosity: LogVerbosity.fromName(json['logVerbosity']),
      logToFile: json['logToFile'] is bool ? json['logToFile'] as bool : true,
      // Clamped on read for the same reason as the text scale: a hand-edited
      // 5,000,000 would be a 40 MB array allocated at launch.
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
      other.explorerPaneWidth == explorerPaneWidth &&
      other.detailSidebarWidth == detailSidebarWidth &&
      other.compactDensity == compactDensity &&
      other.windowWidth == windowWidth &&
      other.windowHeight == windowHeight &&
      other.defaultSystemTerminalId == defaultSystemTerminalId &&
      other.customTerminalPath == customTerminalPath &&
      other.defaultCodeEditorId == defaultCodeEditorId &&
      other.customEditorPath == customEditorPath &&
      other.launcherHotkeyJson == launcherHotkeyJson &&
      other.launcherHotkeyEnabled == launcherHotkeyEnabled &&
      other.shellIntegrationEnabled == shellIntegrationEnabled &&
      _boolMapEquals(other.terminalChordOverrides, terminalChordOverrides) &&
      other.terminalThemeSource == terminalThemeSource &&
      other.remoteAccessEnabled == remoteAccessEnabled &&
      other.remoteRelayUrl == remoteRelayUrl &&
      other.remoteRelayMode == remoteRelayMode &&
      other.localRelayPort == localRelayPort &&
      other.uiTextScale == uiTextScale &&
      other.terminalFontSize == terminalFontSize &&
      other.debugMode == debugMode &&
      other.logVerbosity == logVerbosity &&
      other.logToFile == logToFile &&
      other.logBufferSize == logBufferSize &&
      _listEquals(other.pinnedProjectIds, pinnedProjectIds) &&
      _listEquals(other.pinnedSessionIds, pinnedSessionIds) &&
      _mapEquals(other.permissions, permissions);

  @override
  int get hashCode => Object.hash(
    defaultAgent,
    themeMode,
    defaultTerminalProfileId,
    keepAwake,
    closeToTray,
    autoStart,
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
      Object.hashAll(pinnedProjectIds),
      Object.hashAll(pinnedSessionIds),
      launcherHotkeyJson,
      launcherHotkeyEnabled,
      defaultAgentInstallationId,
      shellIntegrationEnabled,
      terminalThemeSource,
      remoteAccessEnabled,
      remoteRelayUrl,
      remoteRelayMode,
      localRelayPort,
      uiTextScale,
      terminalFontSize,
      debugMode,
      logVerbosity,
      logToFile,
      logBufferSize,
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
