/// A session's **append-only decision record**: what was decided, as opposed to
/// what was said.
///
/// It exists beside the transcript because the turns a handoff packet drops are
/// disproportionately load-bearing — a decision is made once and thereafter
/// assumed. **Written only by explicit acts, never inferred from prose**, so a
/// missing record reads as "not recorded", never as "nothing was decided".
library;

/// What sort of decision a row records. The five the gap analysis named, and no
/// more: each is something a specific act produces, which keeps the vocabulary
/// from drifting into a free-text label.
enum DecisionKind {
  /// A rule the work is now bound by: a platform, a dependency, an API that
  /// must not change.
  constraintAccepted('Constraint accepted'),

  /// An approach that was tried and abandoned, and why. The one the packet
  /// loses first and misses most.
  approachRejected('Approach rejected'),

  /// The user let something happen that needed asking.
  approvalGranted('Approval granted'),

  /// A verification run reached a verdict.
  verificationVerdict('Verification verdict'),

  /// A tree state somebody chose deliberately, as opposed to one a turn left
  /// behind.
  checkpointMarked('Checkpoint marked significant'),

  /// A kind this build does not know — a row from a newer schema, or a
  /// hand-edited database. Never written, only read, and its own state rather
  /// than folded into a neighbour: a wrong heading over a real decision is worse
  /// than admitting the heading could not be read.
  unrecognised('Decision (kind not recognised)');

  const DecisionKind(this.label);

  /// Plain words for a reader, and the heading the packet renders.
  final String label;

  static DecisionKind fromName(String? name) => values.firstWhere(
    (kind) => kind.name == name,
    orElse: () => DecisionKind.unrecognised,
  );
}

/// The act that produced a decision — the thing a reader would go and look at.
///
/// A kind plus an optional id rather than a foreign key, because a decision has
/// to outlive its origin: a pruned run or a collected checkpoint must not take
/// it with them. Nothing ever resolves these; rendering prints them and stops.
enum DecisionOrigin {
  /// The approval prompt on the agent's own screen. Carries **no id**: the
  /// prompt is another program's and is gone once answered.
  approvalPrompt("the agent's own approval prompt"),

  /// A `VerificationRun`, by id.
  verificationRun('verification run'),

  /// A `Checkpoint`, by id.
  checkpoint('checkpoint'),

  /// An agent calling the `decision_record` tool.
  decisionTool('a `decision_record` call'),

  /// The user writing one down in the app, in the Decisions panel.
  ///
  /// Its own origin rather than [decisionTool]'s: who asserted a constraint is
  /// half of what the packet's reader is weighing. Carries **no id** — there is
  /// only the row itself.
  userEntry('the user, written down in the app'),

  /// A row in the session event log, by rowid.
  sessionEvent('session event'),

  /// An origin this build does not know. Never written, only read.
  unrecognised('an act this build does not recognise');

  const DecisionOrigin(this.label);

  /// A noun phrase the packet hangs an id off: "from verification run `v-1`".
  final String label;

  static DecisionOrigin fromName(String? name) => values.firstWhere(
    (origin) => origin.name == name,
    orElse: () => DecisionOrigin.unrecognised,
  );
}

/// One decision, as it was recorded at the moment it was made.
///
/// Immutable, and never rewritten — see [DecisionRecordDao], which offers no
/// update and no delete.
class DecisionRecord {
  const DecisionRecord({
    required this.sessionId,
    required this.kind,
    required this.summary,
    required this.origin,
    required this.recordedAt,
    this.id,
    this.sequence = 0,
    this.detail,
    this.decidedBy,
    this.recordedBySessionId,
    this.originId,
  });

  /// Database rowid; `null` for a decision not yet appended.
  final int? id;

  /// Whose record this belongs to.
  final String sessionId;

  /// 1-based position in this session's chain, assigned on append. Zero on a
  /// record that has not been stored yet.
  final int sequence;

  final DecisionKind kind;

  /// The decision, **in the words of whoever made it** — an agent's own
  /// sentence, or its own description of what a keystroke it offered does.
  /// Never a gist of either.
  final String summary;

  /// More of the same words, when there were more. Optional, and null renders
  /// as nothing rather than as an empty quote.
  final String? detail;

  /// Who decided, in words a reader recognises: "the user", or an agent's
  /// display name. Words rather than an id because the packet's reader has no
  /// way to resolve a key. Null is "not recorded", and renders as that.
  final String? decidedBy;

  /// The session whose act wrote this row, when there was one — beside
  /// [decidedBy] for the reader who does need to resolve something, and null
  /// for a decision the user made by hand.
  final String? recordedBySessionId;

  final DecisionOrigin origin;

  /// The origin's own identifier, or null when the act left no record of its
  /// own. Never dereferenced.
  final String? originId;

  final DateTime recordedAt;

  DecisionRecord copyWith({int? id, int? sequence}) => DecisionRecord(
    id: id ?? this.id,
    sessionId: sessionId,
    sequence: sequence ?? this.sequence,
    kind: kind,
    summary: summary,
    detail: detail,
    decidedBy: decidedBy,
    recordedBySessionId: recordedBySessionId,
    origin: origin,
    originId: originId,
    recordedAt: recordedAt,
  );

  @override
  String toString() => 'DecisionRecord($sessionId#$sequence, ${kind.name})';
}
