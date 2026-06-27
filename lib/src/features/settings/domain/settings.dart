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
  });

  /// The agent pre-selected when starting a new session, or `null` for none.
  final AgentKind? defaultAgent;

  /// Per-agent permission preferences (defaults to "ask" when absent).
  final Map<AgentKind, AgentPermissions> permissions;

  /// The app theme preference.
  final AppThemeMode themeMode;

  AgentPermissions permissionsFor(AgentKind kind) =>
      permissions[kind] ?? const AgentPermissions();

  Settings copyWith({
    AgentKind? defaultAgent,
    bool clearDefaultAgent = false,
    Map<AgentKind, AgentPermissions>? permissions,
    AppThemeMode? themeMode,
  }) => Settings(
    defaultAgent: clearDefaultAgent
        ? null
        : (defaultAgent ?? this.defaultAgent),
    permissions: permissions ?? this.permissions,
    themeMode: themeMode ?? this.themeMode,
  );

  Settings withPermissions(AgentKind kind, AgentPermissions value) =>
      copyWith(permissions: {...permissions, kind: value});

  Map<String, dynamic> toJson() => {
    if (defaultAgent != null) 'defaultAgent': defaultAgent!.name,
    'themeMode': themeMode.name,
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
    return Settings(
      defaultAgent: defaultAgent,
      permissions: permissions,
      themeMode: themeMode,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Settings &&
      other.defaultAgent == defaultAgent &&
      other.themeMode == themeMode &&
      _mapEquals(other.permissions, permissions);

  @override
  int get hashCode => Object.hash(
    defaultAgent,
    themeMode,
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
