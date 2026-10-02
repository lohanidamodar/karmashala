import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/discovery.dart' show AgentInstallation;

/// The preference a person's Settings are kept under (`settings.v1`).
const String kLaunchSettingsKey = 'settings.v1';

/// What a person's Settings say about starting an agent, read by the server
/// from `settings.v1` on every launch — so a change in Settings applies to the
/// next launch, whichever client (or none) asked for it. Unset fields are the
/// agent's own defaults.
class LaunchSettings {
  const LaunchSettings({
    this.defaultAgent,
    this.defaultAgentInstallationId,
    this.newSessionModes = const {},
    this.existingSessionModes = const {},
    this.defaultModels = const {},
    this.letAgentsUpdateThemselves,
  });

  /// Nothing set: every agent at its own defaults.
  static const LaunchSettings none = LaunchSettings();

  final String? defaultAgent;
  final String? defaultAgentInstallationId;

  /// Per agent id, the mode a new (or an existing) conversation starts in.
  final Map<String, String> newSessionModes;
  final Map<String, String> existingSessionModes;
  final Map<String, String> defaultModels;

  /// Null is unset: off on Windows, on elsewhere.
  final bool? letAgentsUpdateThemselves;

  /// Whether a launched agent may update itself, the unset case decided by
  /// the server's own OS.
  bool agentsMayUpdateThemselves({bool? windows}) =>
      letAgentsUpdateThemselves ?? !(windows ?? Platform.isWindows);

  /// The default installation among [installs]: the one named, else the
  /// first of the default agent, else null.
  AgentInstallation? defaultInstallationAmong(
    List<AgentInstallation> installs,
  ) {
    final named = defaultAgentInstallationId;
    if (named != null) {
      for (final install in installs) {
        if (install.id == named) return install;
      }
    }
    final agent = defaultAgent;
    if (agent != null) {
      for (final install in installs) {
        if (install.agentId == agent) return install;
      }
    }
    return null;
  }

  /// [raw] as Settings wrote it; anything unreadable is [none].
  static LaunchSettings parse(String? raw) {
    if (raw == null || raw.isEmpty) return none;
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return none;
      final newModes = <String, String>{};
      final existingModes = <String, String>{};
      final permissions = json['permissions'];
      if (permissions is Map) {
        for (final entry in permissions.entries) {
          final agentId = entry.key;
          final value = entry.value;
          if (agentId is! String || value is! Map) continue;
          final fresh = value['newSessions'];
          final existing = value['existingSessions'];
          if (fresh is String && fresh.isNotEmpty) newModes[agentId] = fresh;
          if (existing is String && existing.isNotEmpty) {
            existingModes[agentId] = existing;
          }
        }
      }
      final models = <String, String>{};
      final rawModels = json['defaultModels'];
      if (rawModels is Map) {
        for (final entry in rawModels.entries) {
          if (entry.key is String && entry.value is String) {
            models[entry.key as String] = entry.value as String;
          }
        }
      }
      String? text(String key) {
        final value = json[key];
        return value is String && value.isNotEmpty ? value : null;
      }

      final update = json['letAgentsUpdateThemselves'];
      return LaunchSettings(
        defaultAgent: text('defaultAgent'),
        defaultAgentInstallationId: text('defaultAgentInstallationId'),
        newSessionModes: newModes,
        existingSessionModes: existingModes,
        defaultModels: models,
        letAgentsUpdateThemselves: update is bool ? update : null,
      );
    } on FormatException {
      return none;
    }
  }
}
