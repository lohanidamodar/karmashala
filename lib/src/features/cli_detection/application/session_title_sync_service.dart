import '../../agents/domain/agent_registry.dart';
import '../../sessions/data/session_dao.dart';
import '../../sessions/domain/session.dart';
import '../../sessions/domain/session_status.dart';
import '../domain/detected_session.dart';

/// The titles the app writes itself, and therefore the ones a CLI may replace.
///
/// `'New session'` is what `ExplorerActions.startSession` stamps on a session
/// started from a `+`; `'Session'` is `SessionLauncher`'s fallback for a blank
/// one. An agent's display name is what `SessionAdoptionService` writes when the
/// store had nothing to offer at the moment it adopted the pane. All three mean
/// "nobody has named this yet", which is precisely when the CLI's own name is
/// better than what is on screen.
const Set<String> kAppGeneratedSessionTitles = {'New session', 'Session'};

/// Copies a CLI's own name for a conversation into the session row that runs it.
///
/// **This is the rename bug, and it was never Antigravity-specific.** The owner
/// ran `/rename test me now` inside `agy`; the CLI recorded it and the sidebar
/// went on saying "New session"
/// (`docs/ANTIGRAVITY_SESSIONS_2026-09-01.md` §7). The app's own rename works —
/// it was never asked. What the app had never had, for *any* agent, is a path by
/// which a CLI-side title reaches an already-launched native session row:
/// app-launched rows are titled at creation and only
/// `SessionActions.renameNative` ever changed them, and `SessionAdoptionService`
/// carries a title only for a session it adopts, only at the moment it adopts
/// it. Claude Code's `/rename` and Codex's thread name were just as invisible;
/// Antigravity is where a user is most likely to rename in the CLI, because its
/// in-app affordances are the thinnest.
///
/// ## Which title wins
///
/// The CLI's, but only while the app has no name of its own to lose. A row is
/// **waiting for a name** when its title is still one the app generated
/// ([kAppGeneratedSessionTitles], the agent's display name, or nothing at all),
/// and it stays waiting while it carries a name this service wrote and its
/// session is still running — so a second `/rename` in the CLI lands too.
///
/// The moment the user renames in the app, the row stops waiting, permanently:
/// their title is neither a placeholder nor the one we last wrote. That is the
/// one direction this must never get wrong. A conversation renamed in the CLI
/// *and* in the app is a genuine conflict, and the answer is the name typed into
/// the app the user is looking at.
///
/// ## What it costs
///
/// A store scan, and only when [wantsStoreSweep] — the same shape as
/// `SessionAdoptionService` and `SessionStatusRegistry._resolvePaths`, and for
/// the same reason: a workspace whose sessions all carry names the user chose
/// pays nothing at all, and a stopped session stops being watched rather than
/// buying a scan forever.
class SessionTitleSyncService {
  SessionTitleSyncService({
    required this.sessionDao,
    required this.agents,
    required this.scanStores,
    this.onRenamed,
  });

  final SessionDao sessionDao;
  final AgentRegistry agents;

  /// One pass over every CLI store — the same scan adoption uses.
  final Future<List<DetectedSession>> Function() scanStores;

  /// Called with each row this renamed, so the workspace can redraw.
  final void Function(String sessionId, String title)? onRenamed;

  /// sessionId → the CLI title this service last wrote there. In memory for the
  /// app's run only: on the next start the row already carries that title, and
  /// a row whose title we cannot prove we wrote is treated as the user's.
  final Map<String, String> _written = {};

  /// Store scans actually run — the cost claim.
  int scans = 0;

  /// Rows renamed, over all syncs.
  int renames = 0;

  /// Whether a store scan would have anything to rename.
  bool get wantsStoreSweep => _waiting().isNotEmpty;

  /// Renames every waiting row its CLI has a name for. Returns how many.
  Future<int> sync() async {
    final waiting = _waiting();
    if (waiting.isEmpty) return 0;
    scans++;
    final List<DetectedSession> detected;
    try {
      detected = await scanStores();
    } on Object {
      // A store we cannot read is the same answer as one with nothing in it —
      // never a reason to change a name.
      return 0;
    }
    final byConversation = <String, DetectedSession>{};
    for (final session in detected) {
      byConversation[session.sessionId] = session;
    }

    var renamed = 0;
    for (final row in waiting) {
      final match = byConversation[row.externalSessionId];
      if (match == null) continue;
      // `title`, never `displayTitle`. The fallback there is the first user
      // message, which is a preview: a fine label on a card, and a lie in a
      // rename, because the user did not choose it and writing it would settle
      // the row against the real name arriving later.
      final title = match.title?.trim() ?? '';
      if (title.isEmpty || title == row.title) continue;
      sessionDao.updateTitle(row.id, title);
      _written[row.id] = title;
      renames++;
      renamed++;
      onRenamed?.call(row.id, title);
    }
    return renamed;
  }

  List<Session> _waiting() => [
    for (final row in sessionDao.getAll())
      if (!row.isArchived &&
          (row.externalSessionId ?? '').isNotEmpty &&
          _waitingForAName(row))
        row,
  ];

  bool _waitingForAName(Session row) {
    final title = row.title.trim();
    if (title.isEmpty) return true;
    if (kAppGeneratedSessionTitles.contains(title)) return true;
    for (final descriptor in agents.descriptors) {
      if (title == descriptor.displayName) return true;
    }
    // A name this service wrote is still the CLI's to change — but only while
    // the session is running. A stopped session has no CLI to be renamed in,
    // and leaving it waiting would buy a store scan on every slow slot for the
    // rest of the app's run; resuming it makes it running again.
    return row.status == SessionStatus.running && _written[row.id] == row.title;
  }
}
