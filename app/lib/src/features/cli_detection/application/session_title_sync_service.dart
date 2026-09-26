import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_session/session.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/sessions/data/sessions_data.dart';

/// Copies a CLI's own name into the session row running it, but only while the
/// row carries a name the app generated. A user's own rename stops it for good.
class SessionTitleSyncService {
  SessionTitleSyncService({
    required this.sessionDao,
    required this.agents,
    required this.scanStores,
    this.onRenamed,
    this.isRunningInPane = _nowhere,
  });

  final SessionsData sessionDao;
  final AgentRegistry agents;

  /// One pass over every CLI store — the same scan adoption uses.
  final Future<List<DetectedSession>> Function() scanStores;

  /// Whether a pane of ours is running session [id]'s agent right now — the
  /// observed answer, which a row's recorded status can lag behind.
  final bool Function(String id) isRunningInPane;

  /// Called with each row this renamed, so the workspace can redraw.
  final void Function(String sessionId, String title)? onRenamed;

  /// sessionId → the CLI title this service last wrote there, this run.
  /// Diagnostics only: whether a title is the user's is recorded on the row.
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
      // `title`, never `displayTitle`: that falls back to the first user
      // message, and writing a preview would settle the row against a real name.
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
    for (final row in sessionDao.getWaitingForTitleSync())
      if (_waitingForAName(row)) row,
  ];

  bool _waitingForAName(Session row) {
    // The user typed this one — recorded on the row, not inferred in memory,
    // or a restart makes every title look user-set.
    if (row.titleByUser) return false;
    final title = row.title.trim();
    if (isPlaceholderSessionTitle(title)) return true;
    for (final descriptor in agents.descriptors) {
      if (title == descriptor.displayName) return true;
    }
    // A CLI name stays the CLI's to change, but only while the session runs: a
    // stopped one would buy a store scan on every slot for ever. Running is
    // what a pane shows, not only what the row recorded: a session started
    // again in its pane after the row settled still has its renames followed.
    return row.status == SessionStatus.running || isRunningInPane(row.id);
  }
}

bool _nowhere(String _) => false;
