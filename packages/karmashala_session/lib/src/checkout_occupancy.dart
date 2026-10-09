import 'package:agent_cli/process.dart';

import 'session.dart';
import 'session_status.dart';

/// A live session that may write in a checkout — one working tree, one index
/// and one branch it would share with whoever starts there next.
class CheckoutOccupant {
  const CheckoutOccupant({required this.session, this.agentName});

  final Session session;

  /// The agent's display name, when it is known.
  final String? agentName;

  /// Whether its agent is at work now, rather than waiting.
  bool get working => session.status == SessionStatus.running;

  /// `Fix login (Claude, working)`.
  String get phrase =>
      '${session.title} (${agentName == null ? '' : '$agentName, '}'
      '${working ? 'working' : 'idle'})';

  Map<String, Object?> toJson() => {
    'sessionId': session.id,
    'title': session.title,
    'agent': ?agentName,
    'status': session.status.name,
    'activity': working ? 'working' : 'idle',
    'permissionMode': ?session.permissionMode,
  };
}

/// The live sessions among [among] that may write in [directory]: not
/// [excluding], not archived, live by [isLive] (a row claiming to run, by
/// default), working there by [directoriesOf], and allowed to write by
/// [mayWrite] — a read-only session shares nothing it could break.
///
/// [pathsMatch], not `==`: one tree reaches this app spelled several ways,
/// and the caller owns that spelling rule. Advisory only — nothing here stops
/// a second writer.
List<Session> sessionsWritingIn(
  EnvironmentPath directory, {
  required Iterable<Session> among,
  required Iterable<EnvironmentPath> Function(Session session) directoriesOf,
  required bool Function(String a, String b) pathsMatch,
  required bool Function(Session session) mayWrite,
  bool Function(Session session)? isLive,
  String? excluding,
}) => [
  for (final candidate in among)
    if (candidate.id != excluding &&
        !candidate.isArchived &&
        (isLive?.call(candidate) ?? candidate.status.claimsLive) &&
        directoriesOf(candidate).any(
          (at) =>
              at.environmentId == directory.environmentId &&
              pathsMatch(at.path, directory.path),
        ) &&
        mayWrite(candidate))
      candidate,
];

/// "2 sessions are working in this checkout: X (Claude, working), Y (Codex,
/// idle)", or null when nobody is.
String? occupancySentence(List<CheckoutOccupant> occupants) {
  if (occupants.isEmpty) return null;
  final who = occupants.map((o) => o.phrase).join(', ');
  return occupants.length == 1
      ? '1 session is working in this checkout: $who.'
      : '${occupants.length} sessions are working in this checkout: $who.';
}
