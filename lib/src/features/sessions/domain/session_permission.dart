import '../../settings/domain/settings.dart';
import 'session_launch.dart';

/// The mode a session runs in, and whether that was its own decision.
///
/// Two states, not one value: a session carrying an explicit mode and one
/// following the per-agent default can show the same selection today and must
/// behave differently tomorrow — the first must not move when the setting
/// changes, the second must.
class SessionPermission {
  const SessionPermission({required this.stored, required this.chosen});

  /// The selection to launch under, as it is stored — a canonical
  /// `PermissionSelection` in the agent's own vocabulary, one of the three
  /// pre-v35 names, or null for "this agent's declared default". Resolving it
  /// needs the agent's descriptor, which this layer deliberately lacks: the
  /// precedence rule is the same for every agent, and the vocabulary is not.
  final String? stored;

  /// Whether [stored] was chosen **for this session**, rather than read from
  /// the per-agent default in Settings.
  final bool chosen;

  /// Whether this session tracks the per-agent default live.
  bool get followsDefault => !chosen;
}

/// **The** precedence rule: a session's own mode outranks the per-agent
/// default, which is the default for a session that has never chosen rather
/// than an override of one that has.
///
/// [sessionMode] non-null means somebody picked it for this session, and it
/// wins at launch, at resume and across a restart; null means the per-agent
/// default for [purpose], read *live*, as it is for pre-v11 rows. A null answer
/// at the end still means "use the mode the agent declares", never "pass no
/// flags". Stated once, in the domain, so the launcher, the chip and the
/// handoff cannot re-derive it differently.
SessionPermission resolveSessionPermission({
  required String? sessionMode,
  required AgentPermissions defaults,
  required SessionPurpose purpose,
}) {
  if (sessionMode != null && sessionMode.isNotEmpty) {
    return SessionPermission(stored: sessionMode, chosen: true);
  }
  return SessionPermission(
    stored: switch (purpose) {
      SessionPurpose.newSession => defaults.newSessions,
      SessionPurpose.existingSession => defaults.existingSessions,
    },
    chosen: false,
  );
}
