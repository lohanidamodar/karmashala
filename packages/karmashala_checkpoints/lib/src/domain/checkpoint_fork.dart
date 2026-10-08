import 'checkpoint.dart';
import 'checkpoint_rules.dart';

/// **The half of a checkpoint fork no CLI here can deliver.** A checkpoint is a
/// tree of files; the conversation is the agent's own record, and nothing
/// Karmashala can say to an agent resumes it at a turn rather than at its tip.
const String kForkCarriesTheWholeConversation =
    'The conversation is carried whole, not rewound to that turn: no agent CLI '
    'here can resume a conversation part-way, so the fork still remembers '
    'everything said after this checkpoint — including edits the files no '
    'longer hold. Say what you rolled back in the instruction.';

/// Why the working-tree half of a checkpoint fork cannot be delivered, or
/// `null` when it can be attempted. One function, so the tool refuses on what
/// this returns and reports the same sentence verbatim.
String? checkpointForkFileRefusal({
  required bool intoNewWorktree,
  required String? unsupportedEnvironmentReason,
  required List<String> otherSessionsInCheckout,
  String? turnRunningIn,
  bool forRewind = false,
}) {
  const left = 'The files were left as they are: ';
  if (unsupportedEnvironmentReason != null) {
    return '$left$unsupportedEnvironmentReason.';
  }
  if (intoNewWorktree) {
    return '${left}a new worktree was asked for, and a checkpoint restores '
        'into the checkout it was taken in. The worktree is a fresh checkout '
        'of the branch, not this checkpoint.';
  }
  if (turnRunningIn != null) {
    return '${left}a turn of "$turnRunningIn" is running, and rolling its '
        'checkout back would change files under its agent mid-turn. Restore '
        'deliberately with checkpoint_restore once the turn has ended.';
  }
  if (otherSessionsInCheckout.isNotEmpty) {
    final who = otherSessionsInCheckout.length == 1
        ? '"${otherSessionsInCheckout.single}" is'
        : '${otherSessionsInCheckout.length} other sessions are';
    if (forRewind) {
      return '$left$who working in this checkout, and rolling it back would '
          'take their uncommitted work with it. End them first, or choose '
          'Conversation only.';
    }
    return '$left$who working in this checkout, and rolling it back would '
        'take uncommitted work that is not this fork\'s with it. Fork with '
        'newWorktree true, or restore deliberately with checkpoint_restore '
        'once nobody else is there.';
  }
  return null;
}

/// One repository's file half of a checkpoint fork: put back, already there,
/// or left alone with [refusal] saying why.
final class ForkedRepository {
  const ForkedRepository(
    this.checkpoint, {
    this.refusal,
    this.alreadyThere,
    this.restoredFiles = 0,
    this.undoCheckpointId,
  });

  final Checkpoint checkpoint;

  /// Why this repository's files were not put back; null when they were.
  final String? refusal;
  final bool? alreadyThere;
  final int restoredFiles;

  /// The checkpoint that puts this repository back as it was before the fork.
  final String? undoCheckpointId;

  bool get restored => refusal == null && alreadyThere == false;
}

/// What a checkpoint fork delivered and what it did not, as the two lists its
/// result carries — one line per repository. **Both are always non-empty**:
/// the conversation half is never a rewind, so there is always something in
/// [notDelivered], and a caller must never have to infer a half from a key that
/// is missing.
({List<String> delivered, List<String> notDelivered}) checkpointForkHalves({
  required String route,
  required List<ForkedRepository> repositories,
}) {
  // One repository's refusal reads as before; several name whose it is.
  final named = repositories.length > 1;
  return (
    delivered: <String>[
      'A fork of the session, by the $route route.',
      for (final r in repositories)
        if (r.refusal == null)
          r.alreadyThere == true
              ? 'The working tree of ${r.checkpoint.repository.path} already '
                    'matched checkpoint ${r.checkpoint.sequence}; nothing was '
                    'written.'
              : 'The working tree of ${r.checkpoint.repository.path}, at '
                    'checkpoint ${r.checkpoint.sequence} (${r.restoredFiles} '
                    'files).'
                    '${r.undoCheckpointId == null ? '' : ' checkpoint_restore '
                              '${r.undoCheckpointId} puts back the tree as it '
                              'was.'}',
    ],
    notDelivered: <String>[
      kForkCarriesTheWholeConversation,
      for (final r in repositories)
        if (r.refusal case final refusal?)
          named ? '${r.checkpoint.repository.path}: $refusal' : refusal,
    ],
  );
}

/// The checkpoints `turn: n` names, **one per repository the turn touched**,
/// each the state that repository was in as the turn **started** — so restoring
/// them all undoes the turn. Per repository: its turnStart of that turn; else
/// its checkpoint just before the turn (a tree unchanged since then records no
/// turnStart); else its earliest of the turn. Empty when the session recorded
/// none for it.
List<Checkpoint> checkpointsAtTurn(List<Checkpoint> chain, int turn) {
  final ofTurn = <String, List<Checkpoint>>{};
  for (final checkpoint in chain) {
    if (checkpoint.turn != turn) continue;
    final repo = checkpoint.repository;
    (ofTurn['${repo.environmentId}\u0000${repo.path}'] ??= []).add(checkpoint);
  }
  return [
    for (final rows in ofTurn.values)
      rows.firstWhere(
        (c) => c.reason == CheckpointReason.turnStart,
        orElse: () => previousCheckpointIn(chain, rows.first) ?? rows.first,
      ),
  ];
}

/// The turns [chain] can be forked from, ascending and deduplicated — for the
/// refusal that has to name what is available instead of guessing.
List<int> forkableTurns(Iterable<Checkpoint> chain) {
  final turns = <int>{for (final c in chain) ?c.turn}.toList()..sort();
  return turns;
}
