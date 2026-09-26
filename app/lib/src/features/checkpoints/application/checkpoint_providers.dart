import '../../workspaces/data/workspace_data.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../../../core/process/command_runner_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import '../../environments/application/environment_providers.dart';
import '../../git/application/parsed_diff.dart';
import 'package:agent_cli/process.dart';
import '../../sessions/application/session_providers.dart';
import 'package:karmashala_checkpoints/checkpoints.dart';

final checkpointDaoProvider = Provider<CheckpointDao>(
  (ref) => CheckpointDao(ref.watch(databaseProvider)),
);

final checkpointServiceProvider = Provider<CheckpointService>(
  (ref) => CheckpointService(
    runnerFactory: ref.watch(commandRunnerFactoryProvider),
    environmentOf: ref.watch(executionEnvironmentDaoProvider).getById,
    dao: ref.watch(checkpointDaoProvider),
    clock: ref.watch(clockProvider),
    newId: () => ref.read(idGeneratorProvider).newId(),
  ),
);

/// The working tree a session's checkpoints are taken of. `null` when the
/// session or its repository is gone — a reason not to checkpoint, not an error.
EnvironmentPath? checkpointTargetFor(Ref ref, String sessionId) {
  final session = ref.read(sessionDaoProvider).getById(sessionId);
  if (session == null) return null;
  final worktree = session.worktree;
  if (worktree != null) return worktree;
  return ref.read(workspaceDataProvider).repository(session.repositoryId)?.path;
}

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

/// Checkpoints for [sessionId], newest first. `autoDispose` and read only by
/// the panel: it re-reads when the revision moves, never on a tick.
final sessionCheckpointsProvider = Provider.autoDispose
    .family<List<Checkpoint>, String>((ref, sessionId) {
      ref.watch(checkpointsRevisionProvider);
      return ref
          .watch(checkpointDaoProvider)
          .forSession(sessionId)
          .reversed
          .toList();
    });

/// What [checkpoint] changed, read from git once and parsed once. A future in
/// `build` re-ran `git diff` on every rebuild of the expanded row.
final checkpointDiffProvider = FutureProvider.autoDispose
    .family<ParsedDiff, Checkpoint>(
      (ref, checkpoint) async => ParsedDiff.parse(
        await ref.read(checkpointServiceProvider).diffOf(checkpoint),
      ),
    );
