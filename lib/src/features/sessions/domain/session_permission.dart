import 'session_launch.dart';

/// The mode a session runs in, and whether that was its own decision. Two
/// states: only the one that never chose moves when the setting moves.
class SessionPermission {
  const SessionPermission({required this.stored, required this.chosen});

  /// The selection to launch under, as stored, or null for the agent's declared
  /// default. Resolving it needs a descriptor this layer deliberately lacks.
  final String? stored;

  /// Whether [stored] was chosen **for this session**, rather than read from
  /// the per-agent default in Settings.
  final bool chosen;

  /// Whether this session tracks the per-agent default live.
  bool get followsDefault => !chosen;
}

/// **The** precedence rule: a session's own mode outranks the per-agent
/// default. A null answer still means "the mode the agent declares".
/// The two per-agent defaults arrive as values rather than as Settings' own
/// type: this layer knows the precedence, not where a preference is stored.
SessionPermission resolveSessionPermission({
  required String? sessionMode,
  required String? newSessionDefault,
  required String? existingSessionDefault,
  required SessionPurpose purpose,
}) {
  if (sessionMode != null && sessionMode.isNotEmpty) {
    return SessionPermission(stored: sessionMode, chosen: true);
  }
  return SessionPermission(
    stored: switch (purpose) {
      SessionPurpose.newSession => newSessionDefault,
      SessionPurpose.existingSession => existingSessionDefault,
    },
    chosen: false,
  );
}
