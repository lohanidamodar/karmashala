/// One artifact an agent named in its own text, as its own syntax spells it.
class AgentArtifactMarker {
  const AgentArtifactMarker({required this.path, this.mode, this.title});

  /// Absolute, on the host the agent runs on.
  final String path;

  /// The agent's word for how wide to show it (`wide`), or null.
  final String? mode;
  final String? title;
}

/// What a scan of one message found: the markers to show, the ones refused
/// (each in words), and the text a person reads with the shown ones taken out.
class ArtifactMarkerScan {
  const ArtifactMarkerScan({
    required this.markers,
    required this.refused,
    required this.text,
  });

  final List<AgentArtifactMarker> markers;
  final List<String> refused;
  final String text;
}

/// How an agent names an artifact inside its answer, when its own tools put a
/// marker in the text rather than calling a tool. Null on an adapter whose
/// agent has none; every caller asks the adapter, never the agent's id.
abstract class AgentArtifactMarkers {
  const AgentArtifactMarkers();

  ArtifactMarkerScan scan(String text);
}
