/// A session's **append-only decision record**: what was decided, as opposed to
/// what was said. Written only by explicit acts, never inferred from prose.
library;

/// What sort of decision a row records. The five the gap analysis named, and no
/// more: a free-text label would mean whatever the last writer wanted.
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

  /// A kind this build does not know. Never written, only read: a wrong heading
  /// over a real decision is worse than admitting it could not be read.
  unrecognised('Decision (kind not recognised)');

  const DecisionKind(this.label);

  /// Plain words for a reader, and the heading the packet renders.
  final String label;

  static DecisionKind fromName(String? name) => values.firstWhere(
    (kind) => kind.name == name,
    orElse: () => DecisionKind.unrecognised,
  );
}

/// The act that produced a decision. A kind plus an optional id rather than a
/// foreign key, because a decision has to outlive its origin.
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

  /// The user writing one down in the app. Its own origin rather than
  /// [decisionTool]'s: who asserted a constraint is what the reader weighs.
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

/// One decision, as it was recorded at the moment it was made. Never rewritten
/// — see [DecisionRecordDao], which offers no update and no delete.
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

  /// The decision, **in the words of whoever made it** — the agent's own
  /// sentence, or its own description of the keystroke it offered.
  final String summary;

  /// More of the same words, when there were more. Optional, and null renders
  /// as nothing rather than as an empty quote.
  final String? detail;

  /// Who decided, in words a reader recognises. Words rather than an id: the
  /// packet's reader cannot resolve a key. Null renders "not recorded".
  final String? decidedBy;

  /// The session whose act wrote this row, beside [decidedBy] for the reader
  /// who does need to resolve something. Null for one made by hand.
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
