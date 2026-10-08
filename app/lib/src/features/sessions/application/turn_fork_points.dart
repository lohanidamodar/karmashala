import 'package:karmashala_checkpoints/checkpoints.dart';

/// Where a fork from one turn puts the files back to: the start of the
/// recorder's turn [turn], every repository it touched, or one [checkpointId].
class TurnForkTarget {
  const TurnForkTarget.turn(int this.turn) : checkpointId = null;
  const TurnForkTarget.checkpoint(String this.checkpointId) : turn = null;

  final int? turn;
  final String? checkpointId;

  @override
  bool operator ==(Object other) =>
      other is TurnForkTarget &&
      other.turn == turn &&
      other.checkpointId == checkpointId;

  @override
  int get hashCode => Object.hash(turn, checkpointId);

  @override
  String toString() =>
      turn == null ? 'checkpoint $checkpointId' : 'start of turn $turn';
}

/// One conversation turn's fork targets: as it began, from its message, and
/// as it ended, from the agent's answer. Null where no checkpoint says so.
class TurnForkPoints {
  const TurnForkPoints({this.before, this.after});

  final TurnForkTarget? before;
  final TurnForkTarget? after;

  @override
  bool operator ==(Object other) =>
      other is TurnForkPoints && other.before == before && other.after == after;

  @override
  int get hashCode => Object.hash(before, after);
}

/// A person's message that opened a turn, by its place in the transcript.
typedef TranscriptTurnStart = ({int ordinal, DateTime? at, String text});

/// How far before its message a turn's first checkpoint may have been taken:
/// the recorder's hook can beat the transcript line by a moment.
const Duration kTurnCheckpointLead = Duration(minutes: 1);

/// The fork targets of each turn in [starts], keyed by its ordinal, read off
/// [chain] (oldest first). A turn is matched to the recorder's turn whose
/// first checkpoint falls between its message and the next — by its prompt
/// where the checkpoint kept one, else the nearest in time. A turn with no
/// match has no entry: there is nothing to fork it from.
Map<int, TurnForkPoints> turnForkPoints(
  List<TranscriptTurnStart> starts,
  List<Checkpoint> chain,
) {
  final firsts = <int, DateTime>{};
  final prompts = <int, String>{};
  final ends = <int, Checkpoint>{};
  for (final checkpoint in chain) {
    final turn = checkpoint.turn;
    if (turn == null) continue;
    final at = checkpoint.createdAt;
    if (firsts[turn] == null || at.isBefore(firsts[turn]!)) firsts[turn] = at;
    if (checkpoint.prompt case final prompt? when prompt.trim().isNotEmpty) {
      prompts[turn] ??= prompt.trim();
    }
    if (checkpoint.reason == CheckpointReason.turn) {
      final kept = ends[turn];
      if (kept == null || !at.isBefore(kept.createdAt)) ends[turn] = checkpoint;
    }
  }
  if (firsts.isEmpty) return const {};

  final matched = <int, int>{};
  final used = <int>{};
  for (var k = 0; k < starts.length; k++) {
    final at = starts[k].at;
    if (at == null) continue;
    final from = at.subtract(kTurnCheckpointLead);
    final until = k + 1 < starts.length ? starts[k + 1].at : null;
    final words = starts[k].text.trim();
    int? best;
    var bestBySaying = false;
    Duration? bestGap;
    for (final MapEntry(key: turn, value: first) in firsts.entries) {
      if (used.contains(turn) || first.isBefore(from)) continue;
      if (until != null && !first.isBefore(until)) continue;
      final prompt = prompts[turn];
      final saying =
          prompt != null &&
          words.isNotEmpty &&
          (prompt.startsWith(words) || words.startsWith(prompt));
      final gap = first.difference(at).abs();
      if (best == null ||
          (saying && !bestBySaying) ||
          (saying == bestBySaying && gap < bestGap!)) {
        best = turn;
        bestBySaying = saying;
        bestGap = gap;
      }
    }
    if (best != null) {
      matched[k] = best;
      used.add(best);
    }
  }

  return {
    for (var k = 0; k < starts.length; k++)
      if (matched[k] case final turn?)
        starts[k].ordinal: TurnForkPoints(
          before: TurnForkTarget.turn(turn),
          after: switch (matched[k + 1]) {
            final next? => TurnForkTarget.turn(next),
            null => switch (ends[turn]) {
              final end? => TurnForkTarget.checkpoint(end.id),
              null => null,
            },
          },
        ),
  };
}
