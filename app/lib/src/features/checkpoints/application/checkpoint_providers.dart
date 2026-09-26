import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:riverpod/riverpod.dart';

import '../../git/application/parsed_diff.dart';
import '../data/checkpoints_data.dart';

/// Moves whenever a checkpoint is recorded or pruned, or a session's skip
/// reason changes — here or by another client — so views refresh without
/// polling.
class CheckpointsRevisionController extends Notifier<int> {
  @override
  int build() {
    final listening = ref
        .watch(checkpointsDataProvider)
        .changes
        .listen((_) => state = state + 1);
    ref.onDispose(listening.cancel);
    return 0;
  }
}

final checkpointsRevisionProvider =
    NotifierProvider<CheckpointsRevisionController, int>(
      CheckpointsRevisionController.new,
    );

/// Checkpoints for [sessionId], newest first. `autoDispose` and read only by
/// the panel: it re-reads when the revision moves, never on a tick.
final sessionCheckpointsProvider = FutureProvider.autoDispose
    .family<List<Checkpoint>, String>((ref, sessionId) async {
      ref.watch(checkpointsRevisionProvider);
      final chain = await ref
          .watch(checkpointsDataProvider)
          .forSession(sessionId);
      return chain.reversed.toList();
    });

/// Why [sessionId] has no automatic checkpoints right now, in the server's
/// recorder's words; null while it is checkpointing.
final checkpointSkipReasonProvider = Provider.autoDispose
    .family<String?, String>((ref, sessionId) {
      ref.watch(checkpointsRevisionProvider);
      return ref.watch(checkpointsDataProvider).skipReasonOf(sessionId);
    });

/// What [checkpoint] changed, read from git by the server once and parsed
/// once. A future in `build` re-ran the diff on every rebuild of the
/// expanded row.
final checkpointDiffProvider = FutureProvider.autoDispose
    .family<ParsedDiff, Checkpoint>(
      (ref, checkpoint) async => ParsedDiff.parse(
        await ref.read(checkpointsDataProvider).diffOf(checkpoint),
      ),
    );
