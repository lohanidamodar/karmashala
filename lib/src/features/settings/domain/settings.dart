import '../../agents/domain/agent_kind.dart';
import 'app_theme_mode.dart';
import 'mini_position.dart';
import 'permission_mode.dart';

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
    this.miniWidth,
    this.miniHeight,
    this.miniPosition = MiniPosition.bottomRight,
    this.defaultSystemTerminalId,
    this.customTerminalPath,
    this.defaultCodeEditorId,
    this.customEditorPath,
    this.launcherHotkeyJson,
    this.launcherHotkeyEnabled = true,
    this.pinnedProjectIds = const [],
    this.pinnedSessionIds = const [],
  });

  /// The agent kind pre-selected when starting a new session, or `null` for
  /// none. Kept in sync with [defaultAgentInstallationId].
  final AgentKind? defaultAgent;

  /// The specific installation chosen as default (e.g. Claude on WSL vs Claude
  /// on Windows), by installation id. Preferred over [defaultAgent] when the
  /// installation is still present; falls back to the kind otherwise.
  final String? defaultAgentInstallationId;

  /// Per-agent permission preferences (defaults to "ask" when absent).
  final Map<AgentKind, AgentPermissions> permissions;

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

  /// Last mini-launcher window size (resizable), null until first saved.
  final double? miniWidth;
  final double? miniHeight;

  /// Where the mini launcher window is placed on screen.
  final MiniPosition miniPosition;

  /// The external terminal app used to resume sessions (mini mode / "open in
  /// terminal"): a detected terminal id (`windowsTerminal`, …), the sentinel
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

  /// The global hotkey that summons the mini launcher, as the encoded JSON of a
  /// `hotkey_manager` HotKey. `null` means use the built-in default
  /// (Ctrl+Alt+Space). Stored as an opaque string so this domain stays free of
  /// the hotkey package.
  final String? launcherHotkeyJson;

  /// Whether the global launcher hotkey is registered at all.
  final bool launcherHotkeyEnabled;

  /// Project ids the user has pinned (shown first), most-recent pin last.
  final List<String> pinnedProjectIds;

  /// Session ids (native or imported) the user has pinned within their project;
  /// pinned sessions sort above the rest. Stored as metadata — the sessions
  /// themselves stay sourced live from the CLI agents.
  final List<String> pinnedSessionIds;

  bool isPinned(String projectId) => pinnedProjectIds.contains(projectId);

  bool isSessionPinned(String sessionId) =>
      pinnedSessionIds.contains(sessionId);

  AgentPermissions permissionsFor(AgentKind kind) =>
      permissions[kind] ?? const AgentPermissions();

  Settings copyWith({
    AgentKind? defaultAgent,
    bool clearDefaultAgent = false,
    String? defaultAgentInstallationId,
    Map<AgentKind, AgentPermissions>? permissions,
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
    double? miniWidth,
    double? miniHeight,
    MiniPosition? miniPosition,
    String? defaultSystemTerminalId,
    String? customTerminalPath,
    String? defaultCodeEditorId,
    String? customEditorPath,
    String? launcherHotkeyJson,
    bool? launcherHotkeyEnabled,
    List<String>? pinnedProjectIds,
    List<String>? pinnedSessionIds,
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
    miniWidth: miniWidth ?? this.miniWidth,
    miniHeight: miniHeight ?? this.miniHeight,
    miniPosition: miniPosition ?? this.miniPosition,
    defaultSystemTerminalId:
        defaultSystemTerminalId ?? this.defaultSystemTerminalId,
    customTerminalPath: customTerminalPath ?? this.customTerminalPath,
    defaultCodeEditorId: defaultCodeEditorId ?? this.defaultCodeEditorId,
    customEditorPath: customEditorPath ?? this.customEditorPath,
    launcherHotkeyJson: launcherHotkeyJson ?? this.launcherHotkeyJson,
    launcherHotkeyEnabled:
        launcherHotkeyEnabled ?? this.launcherHotkeyEnabled,
    pinnedProjectIds: pinnedProjectIds ?? this.pinnedProjectIds,
    pinnedSessionIds: pinnedSessionIds ?? this.pinnedSessionIds,
  );

  Settings withPermissions(AgentKind kind, AgentPermissions value) =>
      copyWith(permissions: {...permissions, kind: value});

  Map<String, dynamic> toJson() => {
    if (defaultAgent != null) 'defaultAgent': defaultAgent!.name,
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
    if (miniWidth != null) 'miniWidth': miniWidth,
    if (miniHeight != null) 'miniHeight': miniHeight,
    'miniPosition': miniPosition.name,
    if (defaultSystemTerminalId != null)
      'defaultSystemTerminalId': defaultSystemTerminalId,
    if (customTerminalPath != null) 'customTerminalPath': customTerminalPath,
    if (defaultCodeEditorId != null) 'defaultCodeEditorId': defaultCodeEditorId,
    if (customEditorPath != null) 'customEditorPath': customEditorPath,
    if (launcherHotkeyJson != null) 'launcherHotkeyJson': launcherHotkeyJson,
    'launcherHotkeyEnabled': launcherHotkeyEnabled,
    'pinnedProjectIds': pinnedProjectIds,
    'pinnedSessionIds': pinnedSessionIds,
    'permissions': {
      for (final entry in permissions.entries)
        entry.key.name: entry.value.toJson(),
    },
  };

  static Settings fromJson(Map<String, dynamic> json) {
    AgentKind? defaultAgent;
    final defaultName = json['defaultAgent'];
    for (final k in AgentKind.values) {
      if (k.name == defaultName) defaultAgent = k;
    }
    var themeMode = AppThemeMode.system;
    for (final m in AppThemeMode.values) {
      if (m.name == json['themeMode']) themeMode = m;
    }
    final permissions = <AgentKind, AgentPermissions>{};
    final perms = json['permissions'];
    if (perms is Map) {
      for (final k in AgentKind.values) {
        final raw = perms[k.name];
        if (raw is Map<String, dynamic>) {
          permissions[k] = AgentPermissions.fromJson(raw);
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
      miniWidth: toDouble(json['miniWidth']),
      miniHeight: toDouble(json['miniHeight']),
      miniPosition: MiniPosition.fromName(json['miniPosition']),
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
      other.miniWidth == miniWidth &&
      other.miniHeight == miniHeight &&
      other.miniPosition == miniPosition &&
      other.defaultSystemTerminalId == defaultSystemTerminalId &&
      other.customTerminalPath == customTerminalPath &&
      other.defaultCodeEditorId == defaultCodeEditorId &&
      other.customEditorPath == customEditorPath &&
      other.launcherHotkeyJson == launcherHotkeyJson &&
      other.launcherHotkeyEnabled == launcherHotkeyEnabled &&
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
    miniWidth,
    miniHeight,
    miniPosition,
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
    ),
    Object.hashAllUnordered(
      permissions.entries.map((e) => Object.hash(e.key, e.value)),
    ),
  );

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _mapEquals(
    Map<AgentKind, AgentPermissions> a,
    Map<AgentKind, AgentPermissions> b,
  ) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }
}
