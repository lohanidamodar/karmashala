import 'dart:convert';

import 'package:riverpod/riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show PreferenceStore;

import '../../../core/data/data_providers.dart';

/// What the last new session was started with: the project, and per project
/// the installation — agent and form in one, since each form is its own
/// installation. Kept in `app_metadata` like quick open's history, so an older
/// build ignores the key.
class NewSessionMemory {
  NewSessionMemory(this._preferences);

  final PreferenceStore _preferences;

  static const String key = 'sessions.new_session_memory.v1';

  /// The project a session was last started in, or null.
  String? get lastProjectId => _read().project;

  /// The installation last started in [projectId], or null.
  String? installationFor(String projectId) => _read().agents[projectId];

  void remember({required String projectId, required String installationId}) {
    final current = _read();
    try {
      _preferences.write(
        key,
        jsonEncode({
          'project': projectId,
          'agents': {...current.agents, projectId: installationId},
        }),
      );
    } catch (_) {
      // A convenience: failing to remember must not fail the start.
    }
  }

  /// A value this build cannot read is no memory, not an error.
  ({String? project, Map<String, String> agents}) _read() {
    const none = (project: null, agents: <String, String>{});
    final String? raw;
    try {
      raw = _preferences.read(key);
    } catch (_) {
      return none;
    }
    if (raw == null) return none;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return none;
      final agents = decoded['agents'];
      return (
        project: decoded['project'] is String
            ? decoded['project'] as String
            : null,
        agents: {
          if (agents is Map)
            for (final MapEntry(:key, :value) in agents.entries)
              if (key is String && value is String) key: value,
        },
      );
    } on FormatException {
      return none;
    }
  }
}

final newSessionMemoryProvider = Provider<NewSessionMemory>(
  (ref) => NewSessionMemory(ref.watch(appPreferencesProvider)),
);
