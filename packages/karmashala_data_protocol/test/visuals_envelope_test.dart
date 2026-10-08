import 'dart:convert';
import 'dart:typed_data';

import 'package:karmashala_artifacts/karmashala_artifacts.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:test/test.dart';

/// What `visualize` drew, asked of the server and told as it changes —
/// through the envelope as JSON text.
void main() {
  final at = DateTime.utc(2026, 10, 8, 9, 30);
  final visual = SessionVisual(
    sessionId: 's1',
    id: 'build',
    kind: 'progress',
    title: 'Build',
    data: const {'value': 40.0, 'max': 100.0, 'status': 'running'},
    revision: 3,
    createdAt: at,
    updatedAt: at,
  );

  Map<String, Object?> overTheWire(Map<String, Object?> json) =>
      (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

  R roundTrip<R>(DataRequest<R> request, R result) => DataEnvelope.readAnswer(
    overTheWire(
      DataEnvelope.answer(4, request, DataReply(result, 9, const [])),
    ),
    request,
  ).value;

  test('the requests round-trip with their arguments', () {
    for (final request in <ArtifactsRequest<Object?>>[
      const SessionVisualsRead('s1'),
      const VisualImageRead('s1', 'shot', offset: 4, length: 8),
    ]) {
      final read = DataEnvelope.readRequest(
        overTheWire(DataEnvelope.request(1, request)),
      );
      expect(read.refusal, isNull, reason: request.kind);
      expect(read.request!.runtimeType, request.runtimeType);
      expect(read.request!.argumentsToJson(), request.argumentsToJson());
    }
  });

  test('a list of visuals and an image chunk round-trip', () {
    final back = roundTrip(const SessionVisualsRead('s1'), [visual]);
    expect(back.single.id, 'build');
    expect(back.single.revision, 3);
    expect(back.single.data, visual.data);
    final chunk = roundTrip(
      const VisualImageRead('s1', 'shot'),
      FileChunk(Uint8List.fromList([7, 8]), fileSize: 2),
    );
    expect(chunk.bytes, [7, 8]);
  });

  test('a drawn or updated visual is told as a change', () {
    final batch = DataChanges.fromJson(
      overTheWire(DataChanges(5, [VisualChanged(visual)]).toJson()),
    );
    final change = batch.changes.single as VisualChanged;
    expect(change.visual.id, 'build');
    expect(change.visual.title, 'Build');
  });
}
