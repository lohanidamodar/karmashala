import 'package:riverpod/riverpod.dart';

import '../../agents/application/agent_providers.dart';
import 'package:karmashala_notifications/watched.dart';
import 'package:karmashala_notifications/attention.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_signals.dart';
import 'follow_up_providers.dart';
import 'package:karmashala_session/events.dart';

/// Everything a session has left behind, as rows for the attention inbox — one
/// surface, not two. Watching this is also what keeps the observer running.
final openFollowUpsProvider =
    NotifierProvider<OpenFollowUpsController, List<InboxItem>>(
      OpenFollowUpsController.new,
    );

/// [openFollowUpsProvider]'s rows. Live: a follow-up the server answers later,
/// or another client resolves, reaches the inbox **as it arrives** — set here
/// at once, not left dirty for a widget build to recompute, which would hand
/// the inbox a change in the middle of that build.
class OpenFollowUpsController extends Notifier<List<InboxItem>> {
  @override
  List<InboxItem> build() {
    ref.watch(sessionEndingObserverProvider);
    // It draws each session's name, so a rename does have to reach it. What no
    // longer reaches it is a permission mode, a pane move or a project rescan.
    ref.watchSessionKinds(const {
      SessionChangeKind.membership,
      SessionChangeKind.title,
      SessionChangeKind.status,
    });
    final changed = ref
        .read(followUpsDataProvider)
        .changes
        .listen((_) => state = _openFollowUpItems(ref));
    ref.onDispose(changed.cancel);
    return _openFollowUpItems(ref);
  }
}

List<InboxItem> _openFollowUpItems(Ref ref) {
  final open = ref.read(followUpsDataProvider).open();
  if (open.isEmpty) return const [];

  // Only the rows this list is about. It used to scan the whole table to build
  // a lookup for at most a couple of hundred follow-ups — the cost the user
  // paid was every session they had ever opened, on every rename.
  final sessions = {
    for (final session
        in ref
            .read(sessionsDataProvider)
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
}

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
