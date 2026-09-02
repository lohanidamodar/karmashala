import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agents/application/agent_providers.dart';
import '../../notifications/domain/agent_session_key.dart';
import '../../notifications/domain/inbox_item.dart';
import '../../notifications/domain/watched_session.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_signals.dart';
import '../domain/follow_up.dart';
import 'follow_up_providers.dart';

/// Everything a session has left behind, as rows for the attention inbox.
///
/// **One surface, not two.** The inbox is already the app's answer to
/// "something needs you" — it is what the status bar's count, the rail's badge
/// and the tray menu all read — so a follow-up goes there rather than getting a
/// panel of its own. A second list would split the one number three surfaces
/// agree on, and the user would have to learn which of two places to look.
///
/// It also **mounts the observer**: nothing else watches
/// `sessionEndingObserverProvider`, and Riverpod 3 pauses a provider's own
/// subscriptions while nothing is listening to it, so an unwatched observer
/// notices nothing at all — silently. Watching it here puts the whole chain
/// behind the one thing the window always shows.
///
/// Recomputed when the observer's revision moves (something was raised or
/// retired) or when the workspace changes (a session was renamed). The observer
/// returns the same number when a sweep changed nothing, so a quiet bump costs
/// no read at all.
final openFollowUpsProvider = Provider<List<InboxItem>>((ref) {
  ref.watch(sessionEndingObserverProvider);
  // It draws each session's name, so a rename does have to reach it. What no
  // longer reaches it is a permission mode, a pane move or a project rescan.
  ref.watchSessionKinds(const {
    SessionChangeKind.membership,
    SessionChangeKind.title,
    SessionChangeKind.status,
  });

  final open = ref.read(followUpDaoProvider).open();
  if (open.isEmpty) return const [];

  // Only the rows this list is about. It used to scan the whole table to build
  // a lookup for at most a couple of hundred follow-ups — the cost the user
  // paid was every session they had ever opened, on every rename.
  final sessions = {
    for (final session in ref
        .read(sessionDaoProvider)
        .getByIds(open.map((followUp) => followUp.sessionId)))
      session.id: session,
  };
  final agentIdByInstallation = {
    for (final installation in ref.read(agentInstallationDaoProvider).getAll())
      installation.id: installation.agentId,
  };

  final items = <InboxItem>[];
  for (final followUp in open) {
    final id = followUp.id;
    final session = sessions[followUp.sessionId];
    // A session that has gone takes its row with it. Skipped rather than drawn
    // as a dead link; the next sweep resolves the record properly.
    if (id == null || session == null) continue;
    final external = session.externalSessionId;
    items.add(
      InboxItem(
        session: WatchedSession(
          key: AgentSessionKey(
            agentIdByInstallation[session.agentInstallationId] ?? '',
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
      ),
    );
  }
  return items;
});

/// The inbox id for the follow-up stored at [rowId].
///
/// Keyed by the **row**, not by the session's agent key: two workspace sessions
/// can share one CLI conversation id, and what each left behind is a different
/// thing. This and [followUpRowIdIn] are the only two places that know the
/// encoding.
String followUpInboxId(int rowId) => 'followUp:$rowId';

/// The follow-up row an inbox id names, or null if it names something else.
int? followUpRowIdIn(String inboxId) {
  const prefix = 'followUp:';
  if (!inboxId.startsWith(prefix)) return null;
  return int.tryParse(inboxId.substring(prefix.length));
}

/// One line saying what was left, in the source's own words where there were
/// any.
///
/// Two sentences and no more: what the app observed, then what the source said.
/// A follow-up with no words says so — "nothing else was recorded" is a fact
/// about the record, whereas a plausible sentence composed here would be
/// indistinguishable from one an agent actually wrote.
String describeFollowUp(FollowUp followUp) {
  final summary = followUp.summary;
  final head = '${followUp.reason.label} — the session ${followUp.ending.label}';
  return summary == null || summary.trim().isEmpty
      ? '$head. Nothing else was recorded.'
      : '$head. ${summary.trim()}';
}
