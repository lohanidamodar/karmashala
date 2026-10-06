import 'dart:convert';
import 'dart:typed_data';

import 'package:karmashala_artifacts/karmashala_artifacts.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:test/test.dart';

/// A session's artifacts, asked of the server, and the change it tells when
/// one is shown or revised — through the envelope as JSON text.
void main() {
  final at = DateTime.utc(2026, 10, 6, 9, 30);
  final artifact = Artifact(
    id: 'a1',
    sessionId: 's1',
    title: 'Flow',
    kind: ArtifactKind.mermaid,
    mode: ArtifactMode.inline,
    origin: ArtifactOrigin.marker,
    hasSource: true,
    fileName: 'flow.mmd',
    revision: 3,
    size: 20,
    mimeType: 'text/plain',
    createdAt: at,
    updatedAt: at,
    sourceState: ArtifactSourceState.missing,
    sourceProblem: 'gone',
  );

  Map<String, Object?> overTheWire(Map<String, Object?> json) =>
      (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

  R roundTrip<R>(DataRequest<R> request, R result) => DataEnvelope.readAnswer(
    overTheWire(DataEnvelope.answer(4, request, DataReply(result, 9, const []))),
    request,
  ).value;

  test('every request round-trips with its arguments', () {
    final requests = <ArtifactsRequest<Object?>>[
      const SessionArtifactsRead('s1'),
      const ArtifactRevisionsRead('a1'),
      const ArtifactContentRead('a1'),
      const ArtifactContentRead('a1', revision: 2, offset: 10, length: 5),
      const ArtifactSetNetwork('a1', allowed: true),
    ];
    for (final request in requests) {
      final read = DataEnvelope.readRequest(
        overTheWire(DataEnvelope.request(1, request)),
      );
      expect(read.refusal, isNull, reason: request.kind);
      expect(read.request!.runtimeType, request.runtimeType);
      expect(read.request!.argumentsToJson(), request.argumentsToJson());
    }
  });

  test('an artifact list round-trips', () {
    final back = roundTrip(const SessionArtifactsRead('s1'), [artifact]);
    expect(back.single.id, 'a1');
    expect(back.single.kind, ArtifactKind.mermaid);
    expect(back.single.origin, ArtifactOrigin.marker);
    expect(back.single.sourceState, ArtifactSourceState.missing);
    expect(back.single.sourceProblem, 'gone');
  });

  test('revisions and content round-trip', () {
    final revisions = roundTrip(const ArtifactRevisionsRead('a1'), [
      ArtifactRevisionSummary(revision: 2, size: 4, capturedAt: at),
    ]);
    expect(revisions.single.revision, 2);
    expect(revisions.single.capturedAt, at);
    final chunk = roundTrip(
      const ArtifactContentRead('a1'),
      FileChunk(Uint8List.fromList([1, 2, 3]), fileSize: 3),
    );
    expect(chunk.bytes, [1, 2, 3]);
  });

  test('a shown or revised artifact is told as a change', () {
    final batch = DataChanges.fromJson(
      overTheWire(DataChanges(5, [ArtifactChanged(artifact)]).toJson()),
    );
    final change = batch.changes.single as ArtifactChanged;
    expect(change.artifact.id, 'a1');
    expect(change.artifact.revision, 3);
  });

  test('the change carries no host path', () {
    final json = jsonEncode(ArtifactChanged(artifact).toJson());
    expect(json, isNot(contains('sourcePath')));
  });
}
