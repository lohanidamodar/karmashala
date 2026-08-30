import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/process/command_runner_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/domain/environment_path.dart';
import '../../repositories/application/repository_providers.dart';
import '../../sessions/application/session_providers.dart';
import '../data/checkpoint_dao.dart';
import '../domain/checkpoint.dart';
import 'checkpoint_service.dart';

final checkpointServiceProvider = Provider<CheckpointService>(
  (ref) => CheckpointService(
    runnerFactory: ref.watch(commandRunnerFactoryProvider),
    environmentDao: ref.watch(executionEnvironmentDaoProvider),
    dao: ref.watch(checkpointDaoProvider),
    clock: ref.watch(clockProvider),
    newId: () => ref.read(idGeneratorProvider).newId(),
  ),
);

/// The working tree a session's checkpoints are taken of.
///
/// A session that was given a worktree is checkpointed in that worktree; one
/// working directly in the repository is checkpointed there. Returns `null` when
/// the session or its repository is gone, which is a reason not to checkpoint
/// rather than an error.
EnvironmentPath? checkpointTargetFor(Ref ref, String sessionId) {
  final session = ref.read(sessionDaoProvider).getById(sessionId);
  if (session == null) return null;
  final worktree = session.worktree;
  if (worktree != null) return worktree;
  return ref.read(repositoryDaoProvider).getById(session.repositoryId)?.path;
}

/// The session whose checkpoints the list view is showing.
class SelectedCheckpointSessionController extends Notifier<String?> {
  @override
  String? build() => null;
  void select(String? id) => state = id;
}

final selectedCheckpointSessionProvider =
    NotifierProvider<SelectedCheckpointSessionController, String?>(
      SelectedCheckpointSessionController.new,
    );

/// Bumped whenever a checkpoint is written, so views refresh without polling.
class CheckpointsRevisionController extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state = state + 1;
}

final checkpointsRevisionProvider =
    NotifierProvider<CheckpointsRevisionController, int>(
      CheckpointsRevisionController.new,
    );

/// Checkpoints for the selected session, newest first.
final sessionCheckpointsProvider = Provider.autoDispose<List<Checkpoint>>((
  ref,
) {
  ref.watch(checkpointsRevisionProvider);
  final sessionId = ref.watch(selectedCheckpointSessionProvider);
  final dao = ref.watch(checkpointDaoProvider);
  if (sessionId == null) return dao.recent(limit: 50);
  return dao.forSession(sessionId).reversed.toList();
});

/// Sessions that have checkpoints, most recently active first.
final checkpointedSessionsProvider = Provider.autoDispose<List<String>>((ref) {
  ref.watch(checkpointsRevisionProvider);
  return ref.watch(checkpointDaoProvider).sessionsWithCheckpoints();
});
