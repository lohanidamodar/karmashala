import '../../../core/database/app_database.dart';
import '../../../core/database/database_providers.dart';
import '../../../core/util/clock.dart';
import '../data/conversation_index_dao.dart';
import 'conversation_indexer.dart';

/// Catches the index up with the conversations already in the workspace.
///
/// **A one-off, not a sweep**, and the distinction is the whole point: it runs
/// once ever, behind the first frame, and records in `app_metadata` that it
/// did. Nothing re-runs it, nothing schedules it, and a workspace that has
/// already been caught up costs one metadata read at start-up and stops.
///
/// It needs paths, and takes the cheapest one available per conversation:
///
/// * `imported_sessions.file_path` — already on the row, free, and read here
///   *unfiltered* so a conversation a native row has taken over still
///   contributes the path only the imported record holds;
/// * one store walk, and only if some conversation is left without a path.
///   That is the same walk `AppLifecycle.importCliSessions` makes at start-up,
///   which is why this waits for that to finish rather than racing it.
///
/// A path that no longer resolves is not a reason to skip a conversation —
/// §20 again: a stored path is state, whether it resolves is a measurement, and
/// the indexer's answer to a measurement that failed is to keep whatever rows
/// it already had.
class ConversationIndexBackfill {
  ConversationIndexBackfill({
    required this.db,
    required this.dao,
    required this.indexer,
    required this.clock,
    required this.locateTranscripts,
  });

  final AppDatabase db;
  final ConversationIndexDao dao;
  final ConversationIndexer indexer;
  final Clock clock;

  /// `'<agentId>/<conversationId>' → path`, one store walk.
  /// `SessionTranscriptLocator.index` in production.
  final Future<Map<String, String>> Function() locateTranscripts;

  /// Store walks this backfill made. Zero or one, and the cost claim.
  int walks = 0;

  /// Whether the catch-up has already happened on this database.
  bool get isDone =>
      db.readMetadata(MetadataKeys.conversationIndexBackfilledAt) != null;

  /// Runs the catch-up, at most once per database. Returns conversations
  /// indexed.
  Future<int> runOnce() async {
    if (isDone) return 0;
    final paths = <String, ({String cli, String? filePath})>{};
    for (final row in dao.liveConversations()) {
      paths[row.sessionId] = (cli: row.cli, filePath: null);
    }
    // Second, so a recorded path wins over the pathless live row for the same
    // conversation.
    for (final row in dao.recordedTranscripts()) {
      paths[row.sessionId] = (cli: row.cli, filePath: row.filePath);
    }

    if (paths.values.any((entry) => entry.filePath == null)) {
      walks++;
      Map<String, String> located;
      try {
        located = await locateTranscripts();
      } on Object {
        // A store we cannot read is the same answer as one with nothing in it.
        located = const {};
      }
      for (final entry in paths.entries) {
        if (entry.value.filePath != null) continue;
        final found = located['${entry.value.cli}/${entry.key}'];
        if (found != null) {
          paths[entry.key] = (cli: entry.value.cli, filePath: found);
        }
      }
    }

    var indexed = 0;
    for (final entry in paths.entries) {
      final path = entry.value.filePath;
      if (path == null) continue;
      if (await indexer.indexConversation(
        conversationId: entry.key,
        cli: entry.value.cli,
        filePath: path,
      )) {
        indexed++;
      }
      // The parse is asynchronous but the writes are synchronous on the isolate
      // that draws, so a conversation's worth of inserts is a frame. Hand one
      // back between conversations: this runs while the user is looking at a
      // window that has just appeared.
      await Future<void>.delayed(Duration.zero);
    }
    // Written whatever happened. A conversation whose transcript could not be
    // read this once is not a reason to walk every store again on the next
    // launch; a real trigger will queue it.
    db.writeMetadata(
      MetadataKeys.conversationIndexBackfilledAt,
      clock.nowUtc().toIso8601String(),
    );
    return indexed;
  }
}
