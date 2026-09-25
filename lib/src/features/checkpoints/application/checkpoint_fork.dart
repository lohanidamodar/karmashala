import 'package:karmashala_checkpoints/checkpoints.dart';

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
  if (otherSessionsInCheckout.isNotEmpty) {
    final who = otherSessionsInCheckout.length == 1
        ? '"${otherSessionsInCheckout.single}" is'
        : '${otherSessionsInCheckout.length} other sessions are';
    return '$left$who working in this checkout, and rolling it back would '
        'take uncommitted work that is not this fork\'s with it. Fork with '
        'newWorktree true, or restore deliberately with checkpoint_restore '
        'once nobody else is there.';
  }
  return null;
}

/// What a checkpoint fork delivered and what it did not, as the two lists its
/// result carries. **Both are always non-empty**: the conversation half is
/// never a rewind, so there is always something in [notDelivered], and a caller
/// must never have to infer a half from a key that is missing.
({List<String> delivered, List<String> notDelivered}) checkpointForkHalves({
  required String route,
  required Checkpoint checkpoint,
  String? fileRefusal,
  bool? alreadyThere,
  int restoredFiles = 0,
}) => (
  delivered: <String>[
    'A fork of the session, by the $route route.',
    if (fileRefusal == null)
      alreadyThere == true
          ? 'The working tree already matched checkpoint '
                '${checkpoint.sequence}; nothing was written.'
          : 'The working tree of ${checkpoint.repository.path}, at checkpoint '
                '${checkpoint.sequence} ($restoredFiles files).',
  ],
  notDelivered: <String>[kForkCarriesTheWholeConversation, ?fileRefusal],
);

/// The checkpoint `turn: n` names — the one taken as the turn **started**, so
/// restoring it undoes the turn. Falls back to the earliest checkpoint recorded
/// for that turn, and is `null` when the session recorded none for it.
Checkpoint? checkpointAtTurn(Iterable<Checkpoint> chain, int turn) {
  Checkpoint? fallback;
  for (final checkpoint in chain) {
    if (checkpoint.turn != turn) continue;
    if (checkpoint.reason == CheckpointReason.turnStart) return checkpoint;
    fallback ??= checkpoint;
  }
  return fallback;
}

/// The turns [chain] can be forked from, ascending and deduplicated — for the
/// refusal that has to name what is available instead of guessing.
List<int> forkableTurns(Iterable<Checkpoint> chain) {
  final turns = <int>{for (final c in chain) ?c.turn}.toList()..sort();
  return turns;
}
