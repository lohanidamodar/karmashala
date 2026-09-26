import 'package:agent_cli/process.dart';

import 'checkpoint.dart';

// The questions readers ask of one session's checkpoints, answered over its
// list (oldest first, by sequence) — the store's queries, for a client's copy.

bool _sameTree(Checkpoint c, EnvironmentPath repository) =>
    c.repository.environmentId == repository.environmentId &&
    c.repository.path == repository.path;

/// [session]'s checkpoints of [repository], oldest first.
List<Checkpoint> checkpointChainIn(
  List<Checkpoint> session,
  EnvironmentPath repository,
) => [
  for (final c in session)
    if (_sameTree(c, repository)) c,
];

/// The newest of [session], of [repository] when given.
Checkpoint? latestCheckpointIn(
  List<Checkpoint> session, {
  EnvironmentPath? repository,
}) {
  for (final c in session.reversed) {
    if (repository == null || _sameTree(c, repository)) return c;
  }
  return null;
}

/// The checkpoint of the same working tree taken just before [checkpoint].
Checkpoint? previousCheckpointIn(
  List<Checkpoint> session,
  Checkpoint checkpoint,
) {
  for (final c in session.reversed) {
    if (c.sequence < checkpoint.sequence &&
        _sameTree(c, checkpoint.repository)) {
      return c;
    }
  }
  return null;
}

/// The highest turn recorded in [session], or 0.
int lastCheckpointTurnIn(List<Checkpoint> session) {
  var last = 0;
  for (final c in session) {
    final turn = c.turn;
    if (turn != null && turn > last) last = turn;
  }
  return last;
}

/// The working trees [session] has checkpoints of, most recently used first.
List<EnvironmentPath> checkpointRepositoriesIn(List<Checkpoint> session) {
  final seen = <String>{};
  return [
    for (final c in session.reversed)
      if (seen.add('${c.repository.environmentId}\u0000${c.repository.path}'))
        c.repository,
  ];
}

/// [session] as it stands once [recorded] is in it, in sequence order.
List<Checkpoint> withCheckpoint(List<Checkpoint> session, Checkpoint recorded) {
  final kept = [
    for (final c in session)
      if (c.id != recorded.id) c,
    recorded,
  ]..sort((a, b) => a.sequence.compareTo(b.sequence));
  return kept;
}

/// The next sequence number of a session holding [session].
int nextCheckpointSequence(List<Checkpoint> session) =>
    session.fold(0, (max, c) => c.sequence > max ? c.sequence : max) + 1;
