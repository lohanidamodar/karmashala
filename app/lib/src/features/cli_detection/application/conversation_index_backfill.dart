import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show PreferenceStore;
import '../../../core/data/metadata_keys.dart';
import 'package:karmashala_core/util.dart';
import '../data/conversation_index_dao.dart';
import 'conversation_indexer.dart';

/// Catches the index up with the conversations already in the workspace — a
/// one-off, recorded among the preferences, never re-run and never scheduled.
class ConversationIndexBackfill {
  ConversationIndexBackfill({
    required this.preferences,
    required this.dao,
    required this.indexer,
    required this.clock,
    required this.locateTranscripts,
  });

  final PreferenceStore preferences;
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
      preferences.read(MetadataKeys.conversationIndexBackfilledAt) != null;

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
      // The writes are synchronous on the drawing isolate, so a conversation's
      // inserts are one frame. Hand a frame back between conversations.
      await Future<void>.delayed(Duration.zero);
    }
    // Written whatever happened: one unreadable transcript is not a reason to
    // walk every store again next launch. A real trigger will queue it.
    preferences.write(
      MetadataKeys.conversationIndexBackfilledAt,
      clock.nowUtc().toIso8601String(),
    );
    return indexed;
  }
}
