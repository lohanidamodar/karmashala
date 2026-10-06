import 'package:karmashala_artifacts/karmashala_artifacts.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

/// Why an artifact is not drawn here, or may be stale — each said in its own
/// words, never as a bare "unavailable".
enum ArtifactFallbackReason {
  sourceMissing,
  hostUnreachable,
  tooLarge,
  serverUnreachable,
  revisionGone,
  notPermitted,
  failed,
}

class ArtifactFallback {
  const ArtifactFallback(
    this.reason,
    this.message, {
    this.offersBrowser = false,
    this.offersSave = false,
  });

  final ArtifactFallbackReason reason;
  final String message;

  /// Whether "Open in browser" and "Save" still work: they need only the
  /// bytes, which the server still serves.
  final bool offersBrowser;
  final bool offersSave;
}

/// What the last look at [artifact]'s source found, when it was not there to
/// read. The newest kept revision still opens; this says why it may be old.
ArtifactFallback? artifactSourceNote(Artifact artifact) {
  final why = artifact.sourceProblem;
  final kept = 'Showing the kept copy, revision ${artifact.revision}.';
  return switch (artifact.sourceState) {
    ArtifactSourceState.present => null,
    ArtifactSourceState.missing => ArtifactFallback(
      ArtifactFallbackReason.sourceMissing,
      'The file is gone from the session\'s host${why == null ? '' : ' ($why)'}. '
      '$kept',
      offersBrowser: true,
      offersSave: true,
    ),
    ArtifactSourceState.unreachable => ArtifactFallback(
      ArtifactFallbackReason.hostUnreachable,
      'The session\'s host could not be reached to look for changes'
      '${why == null ? '' : ' ($why)'}. $kept',
      offersBrowser: true,
      offersSave: true,
    ),
    ArtifactSourceState.tooLarge => ArtifactFallback(
      ArtifactFallbackReason.tooLarge,
      'The file grew past what an artifact keeps'
      '${why == null ? '' : ' ($why)'}. $kept',
      offersBrowser: true,
      offersSave: true,
    ),
  };
}

/// Why an artifact's content did not arrive from the server.
ArtifactFallback artifactLoadFallback(Object error) => switch (error) {
  DataRefused(code: DataRefusalCode.unavailable, :final message) =>
    ArtifactFallback(
      ArtifactFallbackReason.serverUnreachable,
      'The server holding this artifact could not be reached: $message',
    ),
  DataRefused(code: DataRefusalCode.notFound, :final message) =>
    ArtifactFallback(
      ArtifactFallbackReason.revisionGone,
      'The server no longer keeps this revision: $message',
    ),
  DataRefused(code: DataRefusalCode.denied, :final message) =>
    ArtifactFallback(
      ArtifactFallbackReason.notPermitted,
      'This device may not read it: $message',
    ),
  _ => ArtifactFallback(
    ArtifactFallbackReason.failed,
    'Reading it from the server failed: $error',
  ),
};
