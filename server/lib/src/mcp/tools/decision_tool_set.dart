import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/store.dart';
import 'package:karmashala_session/events.dart';
import 'package:karmashala_session_engine/store.dart';

import 'server_tool_context.dart';
import 'server_tool_set.dart';

/// `decision_record`: an agent writing down a decision, deliberately, because
/// a paraphrase is not one. Only two [DecisionKind]s are writable, never an
/// approval: approvals, verdicts and marked checkpoints are recorded by the
/// acts that produce them, so every row has something real behind it.
class DecisionToolSet extends ServerToolSet {
  DecisionToolSet(this._context)
    : _sessions = SessionDao(_context.database),
      _installations = AgentInstallationDao(_context.database);

  final ServerToolContext _context;
  final SessionDao _sessions;
  final AgentInstallationDao _installations;

  /// What an agent may write, and what it is called in the record.
  static const Map<String, DecisionKind> writableKinds = <String, DecisionKind>{
    'constraint': DecisionKind.constraintAccepted,
    'rejected': DecisionKind.approachRejected,
  };

  @override
  List<Map<String, Object?>> get schemas => decisionToolSchemas;

  @override
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) => runTool(() => _record(arguments, callerSessionId));

  Object? _record(Map<String, dynamic> args, String? caller) {
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

    final named = (args['sessionId'] as String?)?.trim();
    final sessionId = named != null && named.isNotEmpty ? named : caller;
    if (sessionId == null) {
      throw ArgumentError(
        'No sessionId, and this caller is not running inside a session, so '
        'there is no record to write to. Pass sessionId — list_sessions has '
        'the ids.',
      );
    }

    final DecisionRecord decision;
    try {
      decision = _context.write(
        DecisionAppend(
          DecisionRecord(
            sessionId: sessionId,
            kind: kind,
            summary: summary,
            detail: (args['detail'] as String?)?.trim(),
            decidedBy: caller == null ? null : _agentNameFor(caller),
            recordedBySessionId: caller,
            origin: DecisionOrigin.decisionTool,
            recordedAt: _context.now(),
          ),
        ),
      );
    } on DataRefused catch (refusal) {
      // An unknown session, as the app's recorder saw it: nothing written.
      _context.log('decision_record: ${refusal.message}');
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

  /// The display name of the agent running [sessionId], or null — a name,
  /// not an id the packet's reader could not look up, and never a guess.
  String? _agentNameFor(String sessionId) {
    final session = _sessions.getById(sessionId);
    if (session == null) return null;
    final agentId = _installations
        .getById(session.agentInstallationId)
        ?.agentId;
    return agentId == null ? null : _context.agents.displayNameFor(agentId);
  }
}

/// The `decision_record` schema, as the app served it.
const List<Map<String, Object?>> decisionToolSchemas = [
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
        'decidedBy': {
          'type': ['string', 'null'],
        },
        'recordedAt': {'type': 'string'},
      },
      'required': ['sessionId', 'sequence', 'kind', 'summary'],
    },
  },
];
