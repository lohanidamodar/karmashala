import 'package:karmashala_session/session.dart';

import 'session_facts.dart';

/// The status a session's row should say, from what its host observed.
///
/// | facts                          | status      |
/// | ------------------------------ | ----------- |
/// | no host knows the session      | `unknown`   |
/// | running                        | `running`   |
/// | exited, code 0                 | `completed` |
/// | exited, non-zero code          | `failed`    |
/// | exited, no code                | `unknown`   |
/// | closed on request              | `cancelled` |
///
/// An exit with no code is one nobody watched, so it is never a success.
SessionStatus lifecycleStatusFrom(SessionFacts? facts) {
  if (facts == null) return SessionStatus.unknown;
  return switch (facts.state) {
    HostSessionState.running => SessionStatus.running,
    HostSessionState.closed => SessionStatus.cancelled,
    HostSessionState.exited => switch (facts.exitCode) {
      null => SessionStatus.unknown,
      0 => SessionStatus.completed,
      _ => SessionStatus.failed,
    },
  };
}

final RegExp _outsideHostIdAlphabet = RegExp(r'[^a-zA-Z0-9_-]');

/// The host session id an agent session runs under. Must match
/// `hostSessionIdFor` in karmashala_terminal_runtime, which names the session.
String hostSessionIdOf(String sessionId) =>
    'karmashala_$sessionId'.replaceAll(_outsideHostIdAlphabet, '_');

/// Which of [candidateSessionIds] runs as [hostSessionId], or null. Compared
/// forwards because the sanitisation is lossy: two ids can share a host id,
/// and then the first candidate wins.
String? sessionIdForHostId(
  String hostSessionId,
  Iterable<String> candidateSessionIds,
) {
  for (final id in candidateSessionIds) {
    if (hostSessionIdOf(id) == hostSessionId) return id;
  }
  return null;
}
