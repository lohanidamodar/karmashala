import 'package:riverpod/riverpod.dart';

import '../sessions/application/decision_recorder.dart';
import 'package:karmashala_session/events.dart';
import '../verification/domain/verification_run.dart';

/// `decision_record`: an agent writing down a decision, deliberately, because a
/// paraphrase is not one. Only two [DecisionKind]s are writable, never approval.
class DecisionControlTools {
  DecisionControlTools(this._container, {this.callerSessionId});

  final ProviderContainer _container;

  /// Which session is calling, when one is. The default subject, and the
  /// recorded author.
  final String? callerSessionId;

  static const Set<String> _names = <String>{'decision_record'};

  static bool handles(String name) => _names.contains(name);

  /// What an agent may write, and what it is called in the record.
  static const Map<String, DecisionKind> writableKinds = <String, DecisionKind>{
    'constraint': DecisionKind.constraintAccepted,
    'rejected': DecisionKind.approachRejected,
  };

  Future<Object?> call(String name, Map<String, dynamic> args) async =>
      switch (name) {
        'decision_record' => _record(args),
        _ => throw ArgumentError('Unknown tool: $name'),
      };

  Object? _record(Map<String, dynamic> args) {
    final kind = writableKinds[(args['kind'] as String?)?.trim()];
    if (kind == null) {
      throw ArgumentError(
        'kind must be one of: ${writableKinds.keys.join(', ')}. An approval, a '
        'verification verdict and a marked checkpoint are recorded by the acts '
        'that produce them — answering the prompt, verification_finish, and '
        'checkpoint_capture with a label — so that a row always has something '
        'real behind it.',
      );
    }
    final summary = (args['summary'] as String?)?.trim() ?? '';
    if (summary.isEmpty) {
      throw ArgumentError(
        'summary is required: say what was decided, in the words it should be '
        'read in later.',
      );
    }

    final sessionId = (args['sessionId'] as String?)?.trim().isNotEmpty == true
        ? (args['sessionId'] as String).trim()
        : callerSessionId;
    if (sessionId == null) {
      throw ArgumentError(
        'No sessionId, and this caller is not running inside a session, so '
        'there is no record to write to. Pass sessionId — list_sessions has '
        'the ids.',
      );
    }

    final decision = _container
        .read(decisionRecorderProvider)
        .recordFromAgent(
          sessionId: sessionId,
          kind: kind,
          summary: summary,
          detail: (args['detail'] as String?)?.trim(),
          decidedBySessionId: callerSessionId,
        );
    if (decision == null) {
      throw StateError(
        'The decision could not be written to $sessionId\'s record.',
      );
    }
    return <String, Object?>{
      'sessionId': decision.sessionId,
      'sequence': decision.sequence,
      'kind': decision.kind.name,
      'summary': decision.summary,
      // Emitted even when null, like `fanout_get`'s producer key: an omitted
      // field reads as a gap in the tool rather than a gap in the record.
      'decidedBy': decision.decidedBy,
      'recordedAt': decision.recordedAt.toIso8601String(),
    };
  }
}

/// The `decision_record` schema, served alongside the rest.
const List<Map<String, dynamic>> decisionControlToolSchemas =
    <Map<String, dynamic>>[
      {
        'name': 'decision_record',
        'description':
            'Write down a decision so it survives this conversation. A '
            "session's decision record is carried into the handoff packet "
            'AHEAD of the quoted transcript, so what you record here reaches '
            'the next agent even when the turn you decided it in has been '
            'trimmed away — which is what happens to decisions made early in a '
            'long session. Record a constraint the work is now bound by, or an '
            'approach you tried and abandoned and why. The summary is stored '
            'EXACTLY as given and is never summarised; write the words that '
            'should be read later, not a gist of them. Approvals, verification '
            'verdicts and marked checkpoints are NOT written here — the acts '
            'that produce them record them, so that every row has something '
            'real behind it. Append-only: nothing you write can be edited or '
            'removed, and recording a reversal later leaves the original '
            'standing so a reader can see it was reversed.',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'kind': {
              'type': 'string',
              'enum': ['constraint', 'rejected'],
              'description':
                  'constraint: a rule the work is now bound by. rejected: an '
                  'approach that was tried and abandoned.',
            },
            'summary': {
              'type': 'string',
              'description':
                  'What was decided, verbatim. Include the reason — "the '
                  'isolate pool deadlocked on Windows" is worth ten times "no '
                  'isolates".',
            },
            'detail': {
              'type': 'string',
              'description': 'Optional. More of the same words.',
            },
            'sessionId': {
              'type': 'string',
              'description':
                  'Whose record to write to. Defaults to the calling session.',
            },
          },
          'required': ['kind', 'summary'],
        },
        'outputSchema': {
          'type': 'object',
          'properties': {
            'sessionId': {'type': 'string'},
            'sequence': {
              'type': 'number',
              'description': "Position in this session's record, 1-based.",
            },
            'kind': {'type': 'string'},
            'summary': {'type': 'string'},
            'decidedBy': {'type': ['string', 'null']},
            'recordedAt': {'type': 'string'},
          },
          'required': ['sessionId', 'sequence', 'kind', 'summary'],
        },
      },
    ];

/// Writes a finished run's verdict to the **subject** session's decision record,
/// not the verifier's. An unfinished or unattached run writes nothing.
void recordFinishedVerdict(ProviderContainer container, VerificationRun? run) {
  if (run == null) return;
  final subject = run.sessionId;
  final verdict = run.verdict;
  if (subject == null || verdict == null) return;
  container
      .read(decisionRecorderProvider)
      .recordVerificationVerdict(
        sessionId: subject,
        runId: run.id,
        verdict: verdict.label,
        title: run.title,
        reason: run.reason,
        attribution: 'Verdict ${run.attribution.phrase}.',
        producedBySessionId: run.producedBySessionId,
      );
}
