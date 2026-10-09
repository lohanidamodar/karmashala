import 'dart:convert';

import 'package:karmashala_automations/pipelines.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:test/test.dart';

/// Pipelines through the envelope as JSON text: the list, a start, the acts
/// on a run, and the changes a run tells as it moves.
void main() {
  final t0 = DateTime.utc(2026, 10, 9, 12);
  final run = PipelineRun(
    id: 'r1',
    definition: kPipelineTemplates.first,
    repositoryId: 'repo',
    input: 'Add a badge',
    state: PipelineRunState.waiting,
    createdAt: t0,
    updatedAt: t0,
    byPerson: true,
    records: [
      PipelineStageRecord(
        stageIndex: 0,
        role: 'Plan',
        attempt: 1,
        state: PipelineStageState.approval,
        sessionId: 's1',
        answer: 'the plan',
        startedAt: t0,
        finishedAt: t0.add(const Duration(minutes: 2)),
      ),
    ],
  );

  R roundTrip<R>(DataRequest<R> request, R result) {
    final asked = jsonDecode(jsonEncode(DataEnvelope.request(1, request)));
    final read = DataEnvelope.readRequest(
      (asked as Map).cast<String, Object?>(),
    );
    expect(read.request!.kind, request.kind);
    expect(
      jsonEncode(read.request!.argumentsToJson()),
      jsonEncode(request.argumentsToJson()),
    );
    final answered = jsonDecode(
      jsonEncode(DataEnvelope.answer(1, request, DataReply(result, 3))),
    );
    return DataEnvelope.readAnswer(
      (answered as Map).cast<String, Object?>(),
      request,
    ).value;
  }

  test('the list carries templates, saved pipelines and runs', () {
    final snapshot = roundTrip(
      const PipelinesList(),
      PipelinesSnapshot(
        templates: kPipelineTemplates,
        saved: [kPipelineTemplates[2].copyWith(id: 'mine', builtIn: false)],
        runs: [run],
      ),
    );
    expect(snapshot.templates.map((t) => t.name), [
      for (final t in kPipelineTemplates) t.name,
    ]);
    expect(snapshot.saved.single.id, 'mine');
    expect(snapshot.runs.single.current!.state, PipelineStageState.approval);
  });

  test('a start carries the definition, and the acts answer the run', () {
    final started = roundTrip(
      PipelineRunStart(
        definition: kPipelineTemplates.first,
        repositoryId: 'repo',
        input: 'Add a badge',
      ),
      run,
    );
    expect(started.input, 'Add a badge');
    expect(started.byPerson, isTrue);
    final approved = roundTrip(
      const PipelineRunApprove('r1', handoff: 'edited'),
      run,
    );
    expect(approved.id, 'r1');
    for (final request in const [
      PipelineRunStop('r1'),
      PipelineRunRetry('r1'),
      PipelineRunSkip('r1'),
    ]) {
      expect(roundTrip(request, run).id, 'r1');
      expect(request, isA<PipelinesRequest<Object?>>());
    }
    roundTrip(PipelineSave(kPipelineTemplates.first), kPipelineTemplates.first);
    roundTrip(const PipelineDelete('mine'), const DataAck());
  });

  test('a run that moves is told as a change', () {
    final batch = DataChanges.fromJson(
      (jsonDecode(
                jsonEncode(
                  DataChanges(5, [
                    PipelineRunChanged(run),
                    const PipelineRemoved('old'),
                  ]).toJson(),
                ),
              )
              as Map)
          .cast<String, Object?>(),
    );
    final changed = batch.changes.first as PipelineRunChanged;
    expect(changed.run.current!.answer, 'the plan');
    expect((batch.changes.last as PipelineRemoved).id, 'old');
  });
}
