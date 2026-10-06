import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_artifacts/karmashala_artifacts.dart';
import 'package:karmashala_store/database.dart';

import 'server_artifacts.dart';
import 'session_environment.dart';

/// Artifacts an agent names in its own answer rather than through
/// `artifact_show` — Codex's `$visualize` marker. Which syntax an agent uses
/// is its adapter's to say (`artifactMarkers`); nothing here knows an id.
class ServerArtifactMarkers {
  ServerArtifactMarkers(
    this._artifacts, {
    required AppDatabase database,
    required void Function(String sessionId, String message) notice,
    AgentRegistry? registry,
  }) : _environments = SessionEnvironments(database),
       _notice = notice,
       _registry = registry ?? AgentRegistry.builtIn;

  final ServerArtifacts _artifacts;
  final SessionEnvironments _environments;
  final void Function(String sessionId, String message) _notice;
  final AgentRegistry _registry;

  /// [text] as a person should read it, the markers [agentId]'s syntax found
  /// taken out — null when there is nothing to take out.
  String? displayOf(String agentId, String text) {
    final reader = _registry.adapterFor(agentId)?.artifactMarkers;
    if (reader == null) return null;
    final shown = reader.scan(text).text;
    return shown == text ? null : shown;
  }

  /// Reads [text], an agent message of [sessionId] by [agentId], and shows
  /// each marker in it. A marker refused, or one whose file cannot be read,
  /// is told to the session in words rather than dropped.
  Future<void> see(String sessionId, String agentId, String text) async {
    final reader = _registry.adapterFor(agentId)?.artifactMarkers;
    if (reader == null) return;
    final scan = reader.scan(text);
    for (final why in scan.refused) {
      _notice(sessionId, 'Not shown as an artifact: $why');
    }
    if (scan.markers.isEmpty) return;
    final String environmentId;
    try {
      environmentId = _environments.of(sessionId);
    } on StateError catch (error) {
      _notice(sessionId, 'Not shown as an artifact: ${error.message}');
      return;
    }
    for (final marker in scan.markers) {
      try {
        await _artifacts.library.show(
          sessionId: sessionId,
          source: EnvironmentPath(
            environmentId: environmentId,
            path: marker.path,
          ),
          title: marker.title,
          mode: ArtifactMode.parse(marker.mode),
          origin: ArtifactOrigin.marker,
        );
      } on Object catch (error) {
        final why = switch (error) {
          StateError(:final message) => message,
          ArgumentError(:final message) => '$message',
          _ => '$error',
        };
        _notice(sessionId, 'Not shown as an artifact: $why');
      }
    }
  }
}
