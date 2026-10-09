import 'package:karmashala_core/util.dart';

import 'conversation_index_dao.dart';
import 'conversation_indexer.dart';

/// Catches the index up with the conversations already in the workspace — a
/// one-off, stamped in the store (`conversation_index_backfilled_at`), never
/// re-run and never scheduled.
class ConversationIndexBackfill {
  ConversationIndexBackfill({
    required this.dao,
    required this.indexer,
    required this.clock,
    required this.locateTranscripts,
    this.pause = const Duration(milliseconds: 20),
  });

  final ConversationIndexDao dao;
  final ConversationIndexer indexer;
  final Clock clock;

  /// Between conversations, so clients' reads are not queued behind its own.
  final Duration pause;

  /// `'<agentId>/<conversationId>' → path`, one walk of every store.
  final Future<Map<String, String>> Function() locateTranscripts;

  /// Store walks this backfill made. Zero or one, and the cost claim.
  int walks = 0;

  /// Whether the catch-up has already happened on this store.
  bool get isDone => dao.backfilledAt != null;

  /// Runs the catch-up, at most once per store. Returns conversations
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
      // The writes are synchronous on the server's one isolate, so a
      // conversation's inserts hold it. Hand the event loop back between them.
      await Future<void>.delayed(pause);
    }
    // Written whatever happened: one unreadable transcript is not a reason to
    // walk every store again next start. A real trigger will queue it.
    dao.markBackfilled(clock.nowUtc());
    return indexed;
  }
}
