import '../../cli_detection/data/transcript_dialect.dart';

/// How an agent's transcript is read into the conversation the app draws.
class AgentTranscripts {
  const AgentTranscripts({
    required this.dialect,
    this.buildsChatView = true,
    this.redirect,
  });

  /// The line format `readCliTranscript` parses this agent's records with.
  final TranscriptDialect dialect;

  /// Whether a structured chat view can be built from these transcripts — the
  /// prior a session's default view is chosen by. False for an agent whose
  /// transcript is found only on some installs.
  final bool buildsChatView;

  /// Maps the record a store scan found to the file the conversation is
  /// actually read from, or null for "none". Absent means the record is the
  /// transcript.
  final String? Function(String recordPath)? redirect;

  /// **The file a session's conversation is actually read from**, or null when
  /// this agent's store keeps none for it.
  String? transcriptFileFor(String recordPath) {
    final map = redirect;
    return map == null ? recordPath : map(recordPath);
  }
}
