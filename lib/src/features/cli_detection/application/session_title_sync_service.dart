import '../../agents/domain/agent_ids.dart';
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
///. The app's own rename works —
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
/// The moment the user renames in the app, the row stops waiting for file-based
/// CLIs: their title is neither a placeholder nor the one we last wrote. Codex
/// is the exception because Karmashala sends its own rename to
/// `thread/name/set`; a later different name returned by `thread/list` is a
/// newer Codex-side rename and is authoritative.
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
    this.agentIdFor,
    this.onRenamed,
  });

  final SessionDao sessionDao;
  final AgentRegistry agents;

  /// One pass over every CLI store — the same scan adoption uses.
  final Future<List<DetectedSession>> Function() scanStores;

  /// Resolves the CLI behind a native row. Codex's protocol name is
  /// authoritative even when the row was previously named in Karmashala.
  final String? Function(Session session)? agentIdFor;

  /// Called with each row this renamed, so the workspace can redraw.
  final void Function(String sessionId, String title)? onRenamed;

  /// sessionId → the CLI title this service last wrote there, for this run.
  /// Diagnostics now rather than policy: whether a title is the user's is
  /// recorded on the row itself, so it survives a restart.
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

  List<Session> _waiting() {
    final agentIdsByInstallation = <String, String?>{};
    return [
      for (final row in sessionDao.getWaitingForTitleSync(includeUserTitles: true))
        if (_waitingForAName(row, agentIdsByInstallation)) row,
    ];
  }

  bool _waitingForAName(
    Session row,
    Map<String, String?> agentIdsByInstallation,
  ) {
    // A user title settles file-based CLIs. Codex is different: an in-app
    // rename is mirrored to its authoritative state database, so a later
    // differing protocol result is a newer rename made inside Codex.
    if (row.titleByUser) {
      final agentId = agentIdsByInstallation.putIfAbsent(
        row.agentInstallationId,
        () => agentIdFor?.call(row),
      );
      return agentId == AgentIds.codex && row.status == SessionStatus.running;
    }
    final title = row.title.trim();
    if (title.isEmpty) return true;
    if (kAppGeneratedSessionTitles.contains(title)) return true;
    for (final descriptor in agents.descriptors) {
      if (title == descriptor.displayName) return true;
    }
    // Otherwise the name came from the CLI, so it stays the CLI's to change —
    // but only while the session is running. A stopped session has no CLI to be
    // renamed in, and leaving it waiting would buy a store scan on every slow
    // slot for the rest of the app's run; resuming it makes it running again.
    //
    // **This is affordable only because the scan is incremental.** Every
    // running session with a CLI name is permanently waiting here, so
    // [wantsStoreSweep] is true for as long as one is running and the sweep
    // runs on every slow slot. That is the price of a second `/rename`
    // landing, and it is a fair one against `ClaudeStoreReader`'s cache — a
    // repeat scan of an unchanged store reads **zero bytes**, measured. If that
    // cache is ever removed, this returns to re-decoding the whole store
    // forever, which is the lag it was reported as.
    return row.status == SessionStatus.running;
  }
}
