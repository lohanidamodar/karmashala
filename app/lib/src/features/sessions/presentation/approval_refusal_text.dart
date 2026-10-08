import 'package:karmashala_agent_status/karmashala_agent_status.dart'
    show SessionPromptRefusal;

/// A refused approve or deny, for a snack bar — the one wording every place
/// that answers an approval uses. On the phone a stale answer is said plainly:
/// the user was not looking at the screen it would have landed on.
String approvalRefusalText(
  SessionPromptRefusal refusal, {
  bool touch = false,
}) => touch && refusal.stale
    ? 'That prompt changed before your answer arrived — nothing was pressed.'
    : refusal.unconfirmed
    ? '${refusal.message}.'
    : refusal.noTerminal || refusal.notFound
    ? 'That session is no longer running, so the key was not sent.'
    : 'Nothing was sent: ${refusal.message}.';
