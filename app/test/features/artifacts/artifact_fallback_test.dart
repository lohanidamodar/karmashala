import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/artifacts/domain/artifact_fallback.dart';
import 'package:karmashala_artifacts/karmashala_artifacts.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

/// Every way an artifact can fail to show says which, and what is still
/// possible — never a generic "unavailable".
void main() {
  Artifact artifact({
    ArtifactKind kind = ArtifactKind.html,
    ArtifactSourceState state = ArtifactSourceState.present,
    String? problem,
  }) => Artifact(
    id: 'a1',
    sessionId: 's1',
    title: 'Chart',
    kind: kind,
    mode: ArtifactMode.inline,
    origin: ArtifactOrigin.tool,
    fileName: 'chart.${kind.extension}',
    revision: 2,
    size: 10,
    mimeType: 'text/html',
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
    hasSource: true,
    sourceState: state,
    sourceProblem: problem,
  );

  test('a source gone from its host says so, and the kept copy still opens',
      () {
    final note = artifactSourceNote(
      artifact(state: ArtifactSourceState.missing, problem: 'No file at x'),
    );
    expect(note!.reason, ArtifactFallbackReason.sourceMissing);
    expect(note.message, contains('revision 2'));
    expect(note.message, contains('No file at x'));
  });

  test('a host out of reach is not called missing', () {
    final note = artifactSourceNote(
      artifact(state: ArtifactSourceState.unreachable, problem: 'refused'),
    );
    expect(note!.reason, ArtifactFallbackReason.hostUnreachable);
    expect(note.message, contains('could not be reached'));
  });

  test('a source over the limit says so', () {
    final note = artifactSourceNote(
      artifact(state: ArtifactSourceState.tooLarge, problem: 'big'),
    );
    expect(note!.reason, ArtifactFallbackReason.tooLarge);
  });

  test('a present source has no note', () {
    expect(artifactSourceNote(artifact()), isNull);
  });

  test('no web view on this platform: says so, offers browser and save', () {
    final f = artifactRenderFallback(
      artifact(),
      webViewProblem: 'Linux has no web view Karmashala can embed',
    );
    expect(f!.reason, ArtifactFallbackReason.noWebView);
    expect(f.message, contains('Linux'));
    expect(f.offersBrowser, isTrue);
    expect(f.offersSave, isTrue);
  });

  test('a PDF has no viewer here: says so, offers browser and save', () {
    final f = artifactRenderFallback(
      artifact(kind: ArtifactKind.pdf),
      webViewProblem: null,
    );
    expect(f!.reason, ArtifactFallbackReason.noRenderer);
    expect(f.message, contains('PDF'));
    expect(f.offersBrowser, isTrue);
  });

  test('drawn natively needs no web view', () {
    for (final kind in [
      ArtifactKind.svg,
      ArtifactKind.markdown,
      ArtifactKind.mermaid,
      ArtifactKind.image,
    ]) {
      expect(
        artifactRenderFallback(
          artifact(kind: kind),
          webViewProblem: 'Linux has no web view',
        ),
        isNull,
        reason: kind.name,
      );
    }
  });

  test('content the server could not serve says which refusal', () {
    final unreachable = artifactLoadFallback(
      const DataRefused.unavailable('the server is not running'),
    );
    expect(unreachable.reason, ArtifactFallbackReason.serverUnreachable);
    expect(unreachable.message, contains('the server is not running'));
    final gone = artifactLoadFallback(
      const DataRefused.notFound('Revision 1 is no longer kept.'),
    );
    expect(gone.reason, ArtifactFallbackReason.revisionGone);
    final denied = artifactLoadFallback(
      const DataRefused.denied('not granted transcripts'),
    );
    expect(denied.reason, ArtifactFallbackReason.notPermitted);
    for (final f in [unreachable, gone, denied]) {
      expect(f.message.toLowerCase(), isNot(contains('unavailable')));
    }
  });
}
