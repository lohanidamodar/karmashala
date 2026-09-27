import 'dart:async';

import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_git/worktrees.dart';

/// **The worktree creations a client asked the server for**, by the client's
/// own id: each stage told to every client as it moves
/// ([WorktreeCreationChanged]), cancelled on request while it still can be,
/// and — for one that launched an agent — kept until the asker says how the
/// agent started, which settles the record.
class ClientWorktreeCreations {
  ClientWorktreeCreations({
    required this.worktrees,
    required void Function(List<DataChange> changes) tell,
    required void Function(EnvironmentPath path) touched,
  }) : _tell = tell,
       _touched = touched;

  final WorktreeService worktrees;
  final void Function(List<DataChange> changes) _tell;
  final void Function(EnvironmentPath path) _touched;
  final Map<String, _Live> _live = {};

  /// Whether creation [id] is still the server's to settle or cancel.
  bool isLive(String id) => _live.containsKey(id);

  Future<CreatedWorktree> create(
    EnvironmentPath repo,
    WorktreeCreate request,
  ) async {
    final id = request.creationId;
    if (id.trim().isEmpty) {
      throw const DataRefused.invalid('a worktree creation needs an id');
    }
    if (_live.containsKey(id)) {
      throw DataRefused.invalid('worktree creation $id is already under way');
    }
    final tracker = WorktreeCreationTracker(repo: repo);
    final live = _Live(
      tracker,
      tracker.changes.listen(
        (record) => _tell([WorktreeCreationChanged(id, repo, record)]),
      ),
    );
    _live[id] = live;
    var keep = false;
    try {
      final created = await worktrees.create(
        repo: repo,
        worktreeName: request.worktreeName,
        branch: request.branch,
        baseRef: request.baseRef,
        launchesAgent: request.launchesAgent,
        tracker: tracker,
      );
      // The agent stage is the asker's to settle; until then this is live.
      keep = request.launchesAgent;
      return CreatedWorktree(
        worktree: created.worktree,
        record: tracker.record,
      );
    } on WorktreeCreationCancelled catch (cancelled) {
      throw DataRefused.invalid(cancelled.toString());
    } finally {
      _touched(repo);
      if (!keep) _drop(id);
    }
  }

  /// Asks creation [id] to stop; it then cleans up and its create is refused.
  void cancel(String id) => _live[id]?.tracker.cancel();

  /// The agent creation [id] launched started ([error] null) or could not.
  Future<void> settleAgent(String id, {String? error}) async {
    final live = _live[id];
    if (live == null) return;
    if (error == null) {
      live.tracker.agentStarted();
    } else {
      live.tracker.agentFailed(error);
    }
    // Let the settled record reach the clients before letting go of it.
    await Future<void>.delayed(Duration.zero);
    _drop(id);
  }

  void _drop(String id) {
    final live = _live.remove(id);
    if (live == null) return;
    unawaited(live.subscription.cancel());
  }

  Future<void> close() async {
    for (final id in [..._live.keys]) {
      _drop(id);
    }
  }
}

class _Live {
  _Live(this.tracker, this.subscription);

  final WorktreeCreationTracker tracker;
  final StreamSubscription<WorktreeCreationRecord> subscription;
}
