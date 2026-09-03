import '../../settings/domain/settings.dart';
import 'session_launch.dart';

/// The mode a session runs in, and whether that was its own decision.
///
/// Two states, not one value: a session that carries an explicit mode and a
/// session following the per-agent default can be showing the same selection
/// today and must behave differently tomorrow — the first must not move when
/// the setting changes, the second must.
class SessionPermission {
  const SessionPermission({required this.stored, required this.chosen});

  /// The selection to launch under, as it is stored — a canonical
  /// `PermissionSelection` in the agent's own vocabulary, one of the three
  /// pre-v35 names, or null for "this agent's declared default".
  ///
  /// Resolving it into real arguments needs the agent's descriptor, which this
  /// layer deliberately does not have: the precedence rule below is the same
  /// for every agent, and the vocabulary is not.
  final String? stored;

  /// Whether [stored] was chosen **for this session**, rather than read from
  /// the per-agent default in Settings.
  final bool chosen;

  /// Whether this session tracks the per-agent default live.
  bool get followsDefault => !chosen;
}

/// **The** precedence rule: a session's own mode outranks the per-agent
/// default.
///
/// The owner's request, in their words: "existing session permission mode
/// should be overridable in each session. but settings is taking precedence, it
/// should be highest priority to sessions own permission by default right?"
///
/// So the setting is the default for a session that has never chosen — not an
/// override of one that has. [sessionMode] is `Session.permissionMode`, and its
/// nullability is what carries the distinction:
///
/// * **Non-null** — someone deliberately picked this mode for this session (on
///   the composer chip, in "Continue with…", or through a caller that resolved
///   one for it). It wins, at launch and at resume, and keeps winning after the
///   setting is changed and across a restart.
/// * **Null** — nobody ever chose, so the per-agent default for [purpose] is
///   the answer, read *live*. Changing the setting moves this session, which is
///   exactly what a default is for. Rows written before schema v11 also land
///   here, and get the same honest answer rather than a fabricated mode.
///
/// A null answer at the end of all of it is still not "pass no flags": it means
/// "use the mode the agent itself declares as its default", which
/// `AgentPermissionSupport.resolveStored` turns into real arguments.
///
/// Lives in the domain, with no `Ref` in sight, so the one rule can be stated
/// once and read by the launcher, the composer chip and the handoff alike
/// rather than re-derived per call site — which is how the resume path came to
/// disagree with every other one.
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
