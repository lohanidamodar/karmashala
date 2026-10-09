import 'dart:async';

import 'package:karmashala_automations/pipelines.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_client.dart';
import '../../../core/data/data_providers.dart';

/// Pipelines as the server keeps and runs them: every act is the server's,
/// and what it changes comes back as [changes].
class PipelinesData {
  PipelinesData(this._client);

  final DataClient _client;

  Stream<PipelinesChange> get changes => _client.pipelineChanges;

  Future<PipelinesSnapshot> list() async =>
      (await _client.send(const PipelinesList())).value;

  Future<PipelineDefinition> save(PipelineDefinition pipeline) async =>
      (await _client.send(PipelineSave(pipeline))).value;

  Future<void> delete(String id) => _client.send(PipelineDelete(id));

  Future<PipelineRun> start({
    required PipelineDefinition definition,
    required String repositoryId,
    required String input,
  }) async => (await _client.send(
    PipelineRunStart(
      definition: definition,
      repositoryId: repositoryId,
      input: input,
    ),
  )).value;

  Future<PipelineRun> approve(String runId, {String? handoff}) async =>
      (await _client.send(PipelineRunApprove(runId, handoff: handoff))).value;

  Future<PipelineRun> stop(String runId) async =>
      (await _client.send(PipelineRunStop(runId))).value;

  Future<PipelineRun> retry(String runId) async =>
      (await _client.send(PipelineRunRetry(runId))).value;

  Future<PipelineRun> skip(String runId) async =>
      (await _client.send(PipelineRunSkip(runId))).value;
}

final pipelinesDataProvider = Provider<PipelinesData>(
  (ref) => PipelinesData(ref.watch(dataClientProvider)),
);
