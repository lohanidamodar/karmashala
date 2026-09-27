import 'package:karmashala_session/events.dart' show FollowUp;
import 'package:karmashala_session/session.dart' show Session;

import 'agent_session_key.dart';
import 'inbox_item.dart';
import 'watched_session.dart';

/// The inbox id for the follow-up stored at [rowId]. Keyed by the **row**: two
/// sessions can share one CLI conversation id.
String followUpInboxId(int rowId) => 'followUp:$rowId';

/// The follow-up row an inbox id names, or null if it names something else.
int? followUpRowIdIn(String inboxId) {
  const prefix = 'followUp:';
  if (!inboxId.startsWith(prefix)) return null;
  return int.tryParse(inboxId.substring(prefix.length));
}

/// One line saying what was left, in the source's own words where there were
/// any. A follow-up with no words says so rather than being given some.
String describeFollowUp(FollowUp followUp) {
  final summary = followUp.summary;
  final head =
      '${followUp.reason.label} — the session ${followUp.ending.label}';
  return summary == null || summary.trim().isEmpty
      ? '$head. Nothing else was recorded.'
      : '$head. ${summary.trim()}';
}

/// [followUp] as an inbox row about [session], whose agent is [agentId] (empty
/// when its installation is gone) — or null for a row with no id, or a
/// session that is gone: skipped rather than drawn as a dead link.
InboxItem? followUpInboxItem(
  FollowUp followUp,
  Session? session, {
  required String agentId,
}) {
  final id = followUp.id;
  if (id == null || session == null) return null;
  final external = session.externalSessionId;
  return InboxItem(
    session: WatchedSession(
      key: AgentSessionKey(
        agentId,
        external == null || external.isEmpty ? session.id : external,
      ),
      label: session.title,
      openId: session.id,
      imported: false,
    ),
    kind: InboxItemKind.followUp,
    // The moment it was raised, out of its own table — so the age beside it
    // is the real one and survives a restart.
    at: followUp.raisedAt,
    id: followUpInboxId(id),
    detail: describeFollowUp(followUp),
  );
}
