import '../../agents/domain/agent_kind.dart';
import 'app_theme_mode.dart';
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
  });

  /// The agent pre-selected when starting a new session, or `null` for none.
  final AgentKind? defaultAgent;

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

  /// The external terminal app used to resume sessions (mini mode / "open in
  /// terminal"): a detected terminal id (`windowsTerminal`, …), the sentinel
  /// `custom`, or `null` to use the first detected one.
  final String? defaultSystemTerminalId;

  /// Path to a custom terminal executable, used when
  /// [defaultSystemTerminalId] is `custom`.
  final String? customTerminalPath;

  AgentPermissions permissionsFor(AgentKind kind) =>
      permissions[kind] ?? const AgentPermissions();

  Settings copyWith({
    AgentKind? defaultAgent,
    bool clearDefaultAgent = false,
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
    String? defaultSystemTerminalId,
    String? customTerminalPath,
  }) => Settings(
    defaultAgent: clearDefaultAgent
        ? null
        : (defaultAgent ?? this.defaultAgent),
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
  );

  Settings withPermissions(AgentKind kind, AgentPermissions value) =>
      copyWith(permissions: {...permissions, kind: value});

  Map<String, dynamic> toJson() => {
    if (defaultAgent != null) 'defaultAgent': defaultAgent!.name,
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
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Settings &&
      other.defaultAgent == defaultAgent &&
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
    Object.hashAllUnordered(
      permissions.entries.map((e) => Object.hash(e.key, e.value)),
    ),
  );

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
